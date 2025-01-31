;; semantic-idle.el --- Schedule parsing tasks in idle time

;;; Copyright (C) 2003, 2004, 2005, 2006, 2008, 2009, 2010 Eric M. Ludlam

;; Author: Eric M. Ludlam <zappo@gnu.org>
;; Keywords: syntax
;; X-RCS: $Id: semantic-idle.el,v 1.74 2010/05/21 00:50:52 scymtym Exp $

;; This file is not part of GNU Emacs.

;; Semantic is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This software is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:
;;
;; Originally, `semantic-auto-parse-mode' handled refreshing the
;; tags in a buffer in idle time.  Other activities can be scheduled
;; in idle time, all of which require up-to-date tag tables.
;; Having a specialized idle time scheduler that first refreshes
;; the tags buffer, and then enables other idle time tasks reduces
;; the amount of work needed.  Any specialized idle tasks need not
;; ask for a fresh tags list.
;;
;; NOTE ON SEMANTIC_ANALYZE
;;
;; Some of the idle modes use the semantic analyzer.  The analyzer
;; automatically caches the created context, so it is shared amongst
;; all idle modes that will need it.

(require 'semantic-ctxt)
(require 'semantic-util-modes)
(require 'timer)
(require 'senator) ;; For `senator-menu-item'

;; @TODO - how to make this happen only if someone enables to summary mode?
(require 'eldoc)

;;; Code:

;;; TIMER RELATED FUNCTIONS
;;
(defvar semantic-idle-scheduler-timer nil
  "Timer used to schedule tasks in idle time.")

(defvar semantic-idle-scheduler-work-timer nil
  "Timer used to schedule tasks in idle time that may take a while.")

(defcustom semantic-idle-scheduler-verbose-flag nil
  "*Non-nil means that the idle scheduler should provide debug messages.
Use this setting to debug idle activities."
  :group 'semantic
  :type 'boolean)

(defcustom semantic-idle-scheduler-idle-time 2
  "*Time in seconds of idle before scheduling events.
This time should be short enough to ensure that idle-scheduler will be
run as soon as Emacs is idle."
  :group 'semantic
  :type 'number
  :set (lambda (sym val)
         (set-default sym val)
         (when (timerp semantic-idle-scheduler-timer)
           (cancel-timer semantic-idle-scheduler-timer)
           (setq semantic-idle-scheduler-timer nil)
           (semantic-idle-scheduler-setup-timers))))

(defcustom semantic-idle-scheduler-work-idle-time 60
  "*Time in seconds of idle before scheduling big work.
This time should be long enough that once any big work is started, it is
unlikely the user would be ready to type again right away."
  :group 'semantic
  :type 'number
  :set (lambda (sym val)
         (set-default sym val)
         (when (timerp semantic-idle-scheduler-timer)
           (cancel-timer semantic-idle-scheduler-timer)
           (setq semantic-idle-scheduler-timer nil)
           (semantic-idle-scheduler-setup-timers))))

(defun semantic-idle-scheduler-setup-timers ()
  "Lazy initialization of the auto parse idle timer."
  ;; REFRESH THIS FUNCTION for XEMACS FOIBLES
  (or (timerp semantic-idle-scheduler-timer)
      (setq semantic-idle-scheduler-timer
            (run-with-idle-timer
             semantic-idle-scheduler-idle-time t
             #'semantic-idle-scheduler-function)))
  (or (timerp semantic-idle-scheduler-work-timer)
      (setq semantic-idle-scheduler-work-timer
            (run-with-idle-timer
             semantic-idle-scheduler-work-idle-time t
             #'semantic-idle-scheduler-work-function)))
  )

(defun semantic-idle-scheduler-kill-timer ()
  "Kill the auto parse idle timer."
  (if (timerp semantic-idle-scheduler-timer)
      (cancel-timer semantic-idle-scheduler-timer))
  (setq semantic-idle-scheduler-timer nil))


;;; MINOR MODE
;;
;; The minor mode portion of this code just sets up the minor mode
;; which does the initial scheduling of the idle timers.
;;
;;;###autoload
(defcustom global-semantic-idle-scheduler-mode nil
  "*If non-nil, enable global use of idle-scheduler mode."
  :group 'semantic
  :group 'semantic-modes
  :type 'boolean
  :require 'semantic-idle
  :initialize 'custom-initialize-default
  :set (lambda (sym val)
         (global-semantic-idle-scheduler-mode (if val 1 -1))))

(defcustom semantic-idle-scheduler-mode-hook nil
  "Hook run at the end of function `semantic-idle-scheduler-mode'."
  :group 'semantic
  :type 'hook)

;;;###autoload
(defvar semantic-idle-scheduler-mode nil
  "Non-nil if idle-scheduler minor mode is enabled.
Use the command `semantic-idle-scheduler-mode' to change this variable.")
(make-variable-buffer-local 'semantic-idle-scheduler-mode)

(defcustom semantic-idle-scheduler-max-buffer-size 0
  "*Maximum size in bytes of buffers where idle-scheduler is enabled.
If this value is less than or equal to 0, idle-scheduler is enabled in
all buffers regardless of their size."
  :group 'semantic
  :type 'number)

(defsubst semantic-idle-scheduler-enabled-p ()
  "Return non-nil if idle-scheduler is enabled for this buffer.
idle-scheduler is disabled when debugging or if the buffer size
exceeds the `semantic-idle-scheduler-max-buffer-size' threshold."
  (and semantic-idle-scheduler-mode
       (not semantic-debug-enabled)
       (not semantic-lex-debug)
       (or (<= semantic-idle-scheduler-max-buffer-size 0)
	   (< (buffer-size) semantic-idle-scheduler-max-buffer-size))))

(defun semantic-idle-scheduler-mode-setup ()
  "Setup option `semantic-idle-scheduler-mode'.
The minor mode can be turned on only if semantic feature is available
and the current buffer was set up for parsing.  When minor mode is
enabled parse the current buffer if needed.  Return non-nil if the
minor mode is enabled."
  (if semantic-idle-scheduler-mode
      (if (not (and (featurep 'semantic) (semantic-active-p)))
          (progn
            ;; Disable minor mode if semantic stuff not available
            (setq semantic-idle-scheduler-mode nil)
            (error "Buffer %s was not set up idle time scheduling"
                   (buffer-name)))
        (semantic-idle-scheduler-setup-timers)))
  semantic-idle-scheduler-mode)

;;;###autoload
(defun semantic-idle-scheduler-mode (&optional arg)
  "Minor mode to auto parse buffer following a change.
When this mode is off, a buffer is only rescanned for tokens when
some command requests the list of available tokens.  When idle-scheduler
is enabled, Emacs periodically checks to see if the buffer is out of
date, and reparses while the user is idle (not typing.)

With prefix argument ARG, turn on if positive, otherwise off.  The
minor mode can be turned on only if semantic feature is available and
the current buffer was set up for parsing.  Return non-nil if the
minor mode is enabled."
  (interactive
   (list (or current-prefix-arg
             (if semantic-idle-scheduler-mode 0 1))))
  (setq semantic-idle-scheduler-mode
        (if arg
            (>
             (prefix-numeric-value arg)
             0)
          (not semantic-idle-scheduler-mode)))
  (semantic-idle-scheduler-mode-setup)
  (run-hooks 'semantic-idle-scheduler-mode-hook)
  (if (cedet-called-interactively-p 'interactive)
      (message "idle-scheduler minor mode %sabled"
               (if semantic-idle-scheduler-mode "en" "dis")))
  (semantic-mode-line-update)
  semantic-idle-scheduler-mode)

(semantic-add-minor-mode 'semantic-idle-scheduler-mode
                         "ARP"
                         nil)

(semantic-alias-obsolete 'semantic-auto-parse-mode
			 'semantic-idle-scheduler-mode)
(semantic-alias-obsolete 'global-semantic-auto-parse-mode
			 'global-semantic-idle-scheduler-mode)


;;; SERVICES services
;;
;; These are services for managing idle services.
;;
(defvar semantic-idle-scheduler-queue nil
  "List of functions to execute during idle time.
These functions will be called in the current buffer after that
buffer has had its tags made up to date.  These functions
will not be called if there are errors parsing the
current buffer.")

;;;###autoload
(defun semantic-idle-scheduler-add (function)
  "Schedule FUNCTION to occur during idle time."
  (add-to-list 'semantic-idle-scheduler-queue function))

;;;###autoload
(defun semantic-idle-scheduler-remove (function)
  "Unschedule FUNCTION to occur during idle time."
  (setq semantic-idle-scheduler-queue
	(delete function semantic-idle-scheduler-queue)))

;;; IDLE Function
;;
(defun semantic-idle-core-handler ()
  "Core idle function that handles reparsing.
And also manages services that depend on tag values."
  (when semantic-idle-scheduler-verbose-flag
    (working-temp-message "IDLE: Core handler..."))
  (semantic-exit-on-input 'idle-timer
    (let* ((inhibit-quit nil)
           (buffers (delq (current-buffer)
                          (delq nil
                                (mapcar #'(lambda (b)
                                            (and (buffer-file-name b)
                                                 b))
                                        (buffer-list)))))
	   safe ;; This safe is not used, but could be.
           others
	   mode)
      (when (semantic-idle-scheduler-enabled-p)
        (save-excursion
          ;; First, reparse the current buffer.
          (setq mode major-mode
                safe (semantic-safe "Idle Parse Error: %S"
		       ;(error "Goofy error 1")
		       (semantic-idle-scheduler-refresh-tags)
		       )
		)
          ;; Now loop over other buffers with same major mode, trying to
          ;; update them as well.  Stop on keypress.
          (dolist (b buffers)
            (semantic-throw-on-input 'parsing-mode-buffers)
            (with-current-buffer b
              (if (eq major-mode mode)
                  (and (semantic-idle-scheduler-enabled-p)
		       (semantic-safe "Idle Parse Error: %S"
			 ;(error "Goofy error")
			 (semantic-idle-scheduler-refresh-tags)))
                (push (current-buffer) others))))
          (setq buffers others))
        ;; If re-parse of current buffer completed, evaluate all other
        ;; services.  Stop on keypress.

	;; NOTE ON COMMENTED SAFE HERE
	;; We used to not execute the services if the buffer wsa
	;; unparseable.  We now assume that they are lexically
	;; safe to do, because we have marked the buffer unparseable
	;; if there was a problem.
	;;(when safe
	(dolist (service semantic-idle-scheduler-queue)
	  (save-excursion
	    (semantic-throw-on-input 'idle-queue)
	    (when semantic-idle-scheduler-verbose-flag
	      (working-temp-message "IDLE: execture service %s..." service))
	    (semantic-safe (format "Idle Service Error %s: %%S" service)
	      (funcall service))
	    (when semantic-idle-scheduler-verbose-flag
	      (working-temp-message "IDLE: execture service %s...done" service))
	    )))
	;;)
      ;; Finally loop over remaining buffers, trying to update them as
      ;; well.  Stop on keypress.
      (save-excursion
        (dolist (b buffers)
          (semantic-throw-on-input 'parsing-other-buffers)
          (with-current-buffer b
            (and (semantic-idle-scheduler-enabled-p)
                 (semantic-idle-scheduler-refresh-tags)))))
      ))
  (when semantic-idle-scheduler-verbose-flag
    (working-temp-message "IDLE: Core handler...done")))

(defun semantic-debug-idle-function ()
  "Run the Semantic idle function with debugging turned on."
  (interactive)
  (let ((debug-on-error t))
    (semantic-idle-core-handler)
    ))

(defun semantic-idle-scheduler-function ()
  "Function run when after `semantic-idle-scheduler-idle-time'.
This function will reparse the current buffer, and if successful,
call additional functions registered with the timer calls."
  (when (zerop (recursion-depth))
    (let ((debug-on-error nil))
      (save-match-data (semantic-idle-core-handler))
      )))


;;; WORK FUNCTION
;;
;; Unlike the shorter timer, the WORK timer will kick of tasks that
;; may take a long time to complete.
(defcustom semantic-idle-work-parse-neighboring-files-flag nil
  "*Non-nil means to parse files in the same dir as the current buffer.
Disable to prevent lots of excessive parsing in idle time."
  :group 'semantic
  :type 'boolean)

(defcustom semantic-idle-work-update-headers-flag nil
  "*Non-nil means to parse through header files in idle time.
Disable to prevent idle time parsing of many files.  If completion
is called that work will be done then instead."
  :group 'semantic
  :type 'boolean)

(defun semantic-idle-work-for-one-buffer (buffer)
  "Do long-processing work for BUFFER.
Uses `semantic-safe' and returns the output.
Returns t if all processing succeeded."
  (with-current-buffer buffer
    (not (and
	  ;; Just in case
	  (semantic-safe "Idle Work Parse Error: %S"
	    (semantic-idle-scheduler-refresh-tags)
	    t)

	  ;; Option to disable this work.
	  semantic-idle-work-update-headers-flag

	  ;; Force all our include files to get read in so we
	  ;; are ready to provide good smart completion and idle
	  ;; summary information
	  (semantic-safe "Idle Work Including Error: %S"
	    ;; Get the include related path.
	    (when (and (featurep 'semanticdb)
		       (semanticdb-minor-mode-p))
	      (require 'semanticdb-find)
	      (semanticdb-find-translate-path buffer nil)
	      )
	    t)

	  ;; Pre-build the typecaches as needed.
	  (semantic-safe "Idle Work Typecaching Error: %S"
	    (when (featurep 'semanticdb-typecache)
	      (semanticdb-typecache-refresh-for-buffer buffer))
	    t)
	  ))
    ))

(defun semantic-idle-work-core-handler ()
  "Core handler for idle work processing of long running tasks.
Visits Semantic controlled buffers, and makes sure all needed
include files have been parsed, and that the typecache is up to date.
Uses `semantic-idle-work-for-on-buffer' to do the work."
  (let ((errbuf nil)
	(interrupted
	 (semantic-exit-on-input 'idle-work-timer
	   (let* ((inhibit-quit nil)
		  (cb (current-buffer))
		  (buffers (delq (current-buffer)
				 (delq nil
				       (mapcar #'(lambda (b)
						   (and (buffer-file-name b)
							b))
					       (buffer-list)))))
		  safe errbuf)
	     ;; First, handle long tasks in the current buffer.
	     (when (semantic-idle-scheduler-enabled-p)
	       (save-excursion
		 (setq safe (semantic-idle-work-for-one-buffer (current-buffer))
		       )))
	     (when (not safe) (push (current-buffer) errbuf))

	     ;; Now loop over other buffers with same major mode, trying to
	     ;; update them as well.  Stop on keypress.
	     (dolist (b buffers)
	       (semantic-throw-on-input 'parsing-mode-buffers)
	       (with-current-buffer b
		 (when (semantic-idle-scheduler-enabled-p)
		   (and (semantic-idle-scheduler-enabled-p)
			(unless (semantic-idle-work-for-one-buffer (current-buffer))
			  (push (current-buffer) errbuf)))
		   ))
	       )

	     (when (and (featurep 'semanticdb)
			(semanticdb-minor-mode-p))
	       ;; Save everything.
	       (semanticdb-save-all-db-idle)

	       ;; Parse up files near our active buffer
	       (when semantic-idle-work-parse-neighboring-files-flag
		 (semantic-safe "Idle Work Parse Neighboring Files: %S"
		   (set-buffer cb)
		   (semantic-idle-scheduler-work-parse-neighboring-files))
		 t)

	       ;; Save everything... again
	       (semanticdb-save-all-db-idle)
	       )

	     ;; Done w/ processing
	     nil))))

    ;; Done
    (if interrupted
	"Interrupted"
      (cond ((not errbuf)
	     "done")
	    ((not (cdr errbuf))
	     (format "done with 1 error in %s" (car errbuf)))
	    (t
	     (format "done with errors in %d buffers."
		     (length errbuf)))))))

(defun semantic-debug-idle-work-function ()
  "Run the Semantic idle work function with debugging turned on."
  (interactive)
  (let ((debug-on-error t))
    (semantic-idle-work-core-handler)
    ))

(defun semantic-idle-scheduler-work-function ()
  "Function run when after `semantic-idle-scheduler-work-idle-time'.
This routine handles difficult tasks that require a lot of parsing, such as
parsing all the header files used by our active sources, or building up complex
datasets."
  (when semantic-idle-scheduler-verbose-flag
    (message "Long Work Idle Timer..."))
  (let ((exit-type (save-match-data
		     (semantic-idle-work-core-handler))))
    (when semantic-idle-scheduler-verbose-flag
      (message "Long Work Idle Timer...%s" exit-type)))
  )

(defun semantic-idle-scheduler-work-parse-neighboring-files ()
  "Parse all the files in similar directories to buffers being edited."
  ;; Lets check to see if EDE matters.
  (let ((ede-auto-add-method 'never))
    (dolist (a auto-mode-alist)
      (when (eq (cdr a) major-mode)
	(dolist (file (directory-files default-directory t (car a) t))
	  (semantic-throw-on-input 'parsing-mode-buffers)
	  (save-excursion
	    (semanticdb-file-table-object file)
	    ))))
    ))

(defun semantic-idle-pnf-test ()
  "Test `semantic-idle-scheduler-work-parse-neighboring-files' and time it."
  (interactive)
  (let ((start (current-time))
	(junk (semantic-idle-scheduler-work-parse-neighboring-files))
	(end (current-time)))
    (message "Work took %.2f seconds." (semantic-elapsed-time start end)))
  )


;;; REPARSING
;;
;; Reparsing is installed as semantic idle service.
;; This part ALWAYS happens, and other services occur
;; afterwards.

(defcustom semantic-idle-scheduler-no-working-message t
  "*If non-nil, disable display of working messages during parse."
  :group 'semantic
  :type 'boolean)

(defcustom semantic-idle-scheduler-working-in-modeline-flag nil
  "*Non-nil means show working messages in the mode line.
Typically, parsing will show messages in the minibuffer.
This will move the parse message into the modeline."
  :group 'semantic
  :type 'boolean)

(defvar semantic-before-idle-scheduler-reparse-hook nil
  "Hook run before option `semantic-idle-scheduler' begins parsing.
If any hook throws an error, this variable is reset to nil.
This hook is not protected from lexical errors.")

(defvar semantic-after-idle-scheduler-reparse-hook nil
  "Hook run after option `semantic-idle-scheduler' has parsed.
If any hook throws an error, this variable is reset to nil.
This hook is not protected from lexical errors.")

(semantic-varalias-obsolete 'semantic-before-idle-scheduler-reparse-hooks
                          'semantic-before-idle-scheduler-reparse-hook)
(semantic-varalias-obsolete 'semantic-after-idle-scheduler-reparse-hooks
                          'semantic-after-idle-scheduler-reparse-hook)

(defun semantic-idle-scheduler-refresh-tags ()
  "Refreshes the current buffer's tags.
This is called by `semantic-idle-scheduler-function' to update the
tags in the current buffer.

Return non-nil if the refresh was successful.
Return nil if there is some sort of syntax error preventing a full
reparse.

Does nothing if the current buffer doesn't need reparsing."

  (prog1
      ;; These checks actually occur in `semantic-fetch-tags', but if we
      ;; do them here, then all the bovination hooks are not run, and
      ;; we save lots of time.
      (cond
       ;; If the buffer was previously marked unparseable,
       ;; then don't waste our time.
       ((semantic-parse-tree-unparseable-p)
	nil)
       ;; The parse tree is already ok.
       ((semantic-parse-tree-up-to-date-p)
	t)
       (t
	;; If the buffer might need a reparse and it is safe to do so,
	;; give it a try.
	(let* ((semantic-working-type nil)
	       (inhibit-quit nil)
	       (working-use-echo-area-p
		(not semantic-idle-scheduler-working-in-modeline-flag))
	       (working-status-dynamic-type
		(if semantic-idle-scheduler-no-working-message
		    nil
		  working-status-dynamic-type))
	       (working-status-percentage-type
		(if semantic-idle-scheduler-no-working-message
		    nil
		  working-status-percentage-type))
	       (lexically-safe t)
	       )
	  ;; Let people hook into this, but don't let them hose
	  ;; us over!
	  (condition-case nil
	      (run-hooks 'semantic-before-idle-scheduler-reparse-hook)
	    (error (setq semantic-before-idle-scheduler-reparse-hook nil)))

	  (unwind-protect
	      ;; Perform the parsing.
	      (progn
		(when semantic-idle-scheduler-verbose-flag
		  (working-temp-message "IDLE: reparse %s..." (buffer-name)))
		(when (semantic-lex-catch-errors idle-scheduler
			(save-excursion (semantic-fetch-tags))
			nil)
		  ;; If we are here, it is because the lexical step failed,
		  ;; proably due to unterminated lists or something like that.

		  ;; We do nothing, and just wait for the next idle timer
		  ;; to go off.  In the meantime, remember this, and make sure
		  ;; no other idle services can get executed.
		  (setq lexically-safe nil))
		(when semantic-idle-scheduler-verbose-flag
		  (working-temp-message "IDLE: reparse %s...done" (buffer-name))))
	    ;; Let people hook into this, but don't let them hose
	    ;; us over!
	    (condition-case nil
		(run-hooks 'semantic-after-idle-scheduler-reparse-hook)
	      (error (setq semantic-after-idle-scheduler-reparse-hook nil))))
	  ;; Return if we are lexically safe (from prog1)
	  lexically-safe)))

    ;; After updating the tags, handle any pending decorations for this
    ;; buffer.
    (semantic-decorate-flush-pending-decorations (current-buffer))
    ))


;;; IDLE SERVICES
;;
;; Idle Services are minor modes which enable or disable a services in
;; the idle scheduler.  Creating a new services only requires calling
;; `semantic-create-idle-services' which does all the setup
;; needed to create the minor mode that will enable or disable
;; a services.  The services must provide a single function.

;; FIXME doc is incomplete.
(defmacro define-semantic-idle-service (name doc &rest forms)
  "Create a new idle services with NAME.
DOC will be a documentation string describing FORMS.
FORMS will be called during idle time after the current buffer's
semantic tag information has been updated.
This routine creates the following functions and variables:"
  (let ((global (intern (concat "global-" (symbol-name name) "-mode")))
	(mode 	(intern (concat (symbol-name name) "-mode")))
	(hook 	(intern (concat (symbol-name name) "-mode-hook")))
	(map  	(intern (concat (symbol-name name) "-mode-map")))
	(setup 	(intern (concat (symbol-name name) "-mode-setup")))
	(func 	(intern (concat (symbol-name name) "-idle-function"))))

    `(eval-and-compile
       (defun ,global (&optional arg)
	 ,(concat "Toggle `" (symbol-name mode) "'.
With ARG, turn the minor mode on if ARG is positive, off otherwise.

When this minor mode is enabled, `" (symbol-name mode) "' is
turned on in every Semantic-supported buffer.")
	 (interactive "P")
	 (setq ,global
	       (semantic-toggle-minor-mode-globally
		',mode arg)))

       (defcustom ,global nil
	 ,(concat "Non-nil if `" (symbol-name mode) "' is enabled.")
	 :group 'semantic
	 :group 'semantic-modes
	 :type 'boolean
	 :require 'semantic-idle
	 :initialize 'custom-initialize-default
	 :set (lambda (sym val)
		(,global (if val 1 -1))))

       (defcustom ,hook nil
	 ,(concat "Hook run at the end of function `" (symbol-name mode) "'.")
	 :group 'semantic
	 :type 'hook)

       (defvar ,map
	 (let ((km (make-sparse-keymap)))
	   km)
	 ,(concat "Keymap for `" (symbol-name mode) "'."))

       (defvar ,mode nil
	 ,(concat "Non-nil if the minor mode `" (symbol-name mode) "' is enabled.
Use the command `" (symbol-name mode) "' to change this variable."))
       (make-variable-buffer-local ',mode)

       (defun ,setup ()
	 ,(concat "Set up `" (symbol-name mode) "'.
Return non-nil if the minor mode is enabled.")
	 (if ,mode
	     (if (not (and (featurep 'semantic) (semantic-active-p)))
		 (progn
		   ;; Disable minor mode if semantic stuff not available
		   (setq ,mode nil)
		   (error "Buffer %s was not set up for parsing"
			  (buffer-name)))
	       ;; Enable the mode mode
	       (semantic-idle-scheduler-add #',func)
	       )
	   ;; Disable the mode mode
	   (semantic-idle-scheduler-remove #',func)
	   )
	 ,mode)

;;;###autoload
       (defun ,mode (&optional arg)
	 ,doc
	 (interactive
	  (list (or current-prefix-arg
		    (if ,mode 0 1))))
	 (setq ,mode
	       (if arg
		   (>
		    (prefix-numeric-value arg)
		    0)
		 (not ,mode)))
	 (,setup)
	 (run-hooks ,hook)
	 (if (cedet-called-interactively-p 'interactive)
	     (message "%s %sabled"
		      (symbol-name ',mode)
		      (if ,mode "en" "dis")))
	 (semantic-mode-line-update)
	 ,mode)

       (semantic-add-minor-mode ',mode
				""	; idle schedulers are quiet?
				,map)

       (defun ,func ()
	 ,(concat "Perform idle activity for the minor mode `"
		  (symbol-name mode) "'.")
	 ,@forms))))
(put 'define-semantic-idle-service 'lisp-indent-function 1)


;;; SUMMARY MODE
;;
;; A mode similar to eldoc using semantic
(defcustom semantic-idle-truncate-long-summaries t
  "Truncate summaries that are too long to fit in the minibuffer.
This can prevent minibuffer resizing in idle time."
  :group 'semantic
  :type 'boolean)

(defcustom semantic-idle-summary-function
  'semantic-format-tag-summarize-with-file
  "Function to call when displaying tag information during idle time.
This function should take a single argument, a Semantic tag, and
return a string to display.
Some useful functions are found in `semantic-format-tag-functions'."
  :group 'semantic
  :type semantic-format-tag-custom-list)

(defsubst semantic-idle-summary-find-current-symbol-tag (sym)
  "Search for a semantic tag with name SYM in database tables.
Return the tag found or nil if not found.
If semanticdb is not in use, use the current buffer only."
  (car (if (and (featurep 'semanticdb) semanticdb-current-database)
           (cdar (semanticdb-deep-find-tags-by-name sym))
         (semantic-deep-find-tags-by-name sym (current-buffer)))))

(defun semantic-idle-summary-current-symbol-info-brutish ()
  "Return a string message describing the current context.
Gets a symbol with `semantic-ctxt-current-thing' and then
tries to find it with a deep targeted search."
  ;; Try the current "thing".
  (let ((sym (car (semantic-ctxt-current-thing))))
    (when sym
      (semantic-idle-summary-find-current-symbol-tag sym))))

(defun semantic-idle-summary-current-symbol-keyword ()
  "Return a string message describing the current symbol.
Returns a value only if it is a keyword."
  ;; Try the current "thing".
  (let ((sym (car (semantic-ctxt-current-thing))))
    (if (and sym (semantic-lex-keyword-p sym))
	(semantic-lex-keyword-get sym 'summary))))

(defun semantic-idle-summary-current-symbol-info-context ()
  "Return a string message describing the current context.
Use the semantic analyzer to find the symbol information."
  (let ((analysis (condition-case nil
		      (semantic-analyze-current-context (point))
		    (error nil))))
    (when analysis
      (semantic-analyze-interesting-tag analysis))))

(defun semantic-idle-summary-current-symbol-info-default ()
  "Return a string message describing the current context.
This function will disable loading of previously unloaded files
by semanticdb as a time-saving measure."
  (semanticdb-without-unloaded-file-searches
      (save-excursion
	;; use whichever has success first.
	(or
	 (semantic-idle-summary-current-symbol-keyword)

	 (semantic-idle-summary-current-symbol-info-context)

	 (semantic-idle-summary-current-symbol-info-brutish)
	 ))))

(defvar semantic-idle-summary-out-of-context-faces
  '(
    font-lock-comment-face
    font-lock-string-face
    font-lock-doc-string-face           ; XEmacs.
    font-lock-doc-face                  ; Emacs 21 and later.
    )
  "List of font-lock faces that indicate a useless summary context.
Those are generally faces used to highlight comments.

It might be useful to override this variable to add comment faces
specific to a major mode.  For example, in jde mode:

\(defvar-mode-local jde-mode semantic-idle-summary-out-of-context-faces
   (append (default-value 'semantic-idle-summary-out-of-context-faces)
	   '(jde-java-font-lock-doc-tag-face
	     jde-java-font-lock-link-face
	     jde-java-font-lock-bold-face
	     jde-java-font-lock-underline-face
	     jde-java-font-lock-pre-face
	     jde-java-font-lock-code-face)))")

(defun semantic-idle-summary-useful-context-p ()
  "Non-nil if we should show a summary based on context."
  (if (and (boundp 'font-lock-mode)
	   font-lock-mode
	   (memq (get-text-property (point) 'face)
		 semantic-idle-summary-out-of-context-faces))
      ;; The best I can think of at the moment is to disable
      ;; in comments by detecting with font-lock.
      nil
    t))

(define-overloadable-function semantic-idle-summary-current-symbol-info ()
  "Return a string message describing the current context.")

(make-obsolete-overload 'semantic-eldoc-current-symbol-info
                        'semantic-idle-summary-current-symbol-info)

(define-semantic-idle-service semantic-idle-summary
  "Display a tag summary of the lexical token under the cursor.
Call `semantic-idle-summary-current-symbol-info' for getting the
current tag to display information."
  (or (eq major-mode 'emacs-lisp-mode)
      (not (semantic-idle-summary-useful-context-p))
      (let* ((found (semantic-idle-summary-current-symbol-info))
             (str (cond ((stringp found) found)
                        ((semantic-tag-p found)
                         (funcall semantic-idle-summary-function
                                  found nil t)))))
	;; Show the message with eldoc functions
        (unless (and str (boundp 'eldoc-echo-area-use-multiline-p)
                     eldoc-echo-area-use-multiline-p)
          (let ((w (1- (window-width (minibuffer-window)))))
            (if (> (length str) w)
                (setq str (substring str 0 w)))))
	;; I borrowed some bits from eldoc to shorten the
	;; message.
	(when semantic-idle-truncate-long-summaries
	  (let ((ea-width (1- (window-width (minibuffer-window))))
		(strlen (length str)))
	    (when (> strlen ea-width)
	      (setq str (substring str 0 ea-width)))))
	;; Display it
        (eldoc-message str))))

(semantic-alias-obsolete 'semantic-summary-mode
			 'semantic-idle-summary-mode)
(semantic-alias-obsolete 'global-semantic-summary-mode
			 'global-semantic-idle-summary-mode)

;;; Current symbol highlight
;;
;; This mode will use context analysis to perform highlighting
;; of all uses of the symbol that is under the cursor.
;;
;; This is to mimic the Eclipse tool of a similar nature.
(defvar semantic-idle-symbol-highlight-face 'region
  "Face used for the highlighting local symbols.")

(defun semantic-idle-symbol-maybe-highlight (tag)
  "Perhaps add highlighting onto the symbol represented by TAG.
TAG was found as the symbol under point.  If it happens to be
visible, then highlight it."
  (let* ((region (when (and (semantic-tag-p tag)
			    (semantic-tag-with-position-p tag))
		   (semantic-tag-overlay tag)))
	 (file (when (and (semantic-tag-p tag)
			  (semantic-tag-with-position-p tag))
		 (semantic-tag-file-name tag)))
	 (buffer (when file (get-file-buffer file)))
	 ;; We use pulse, but we don't want the flashy version,
	 ;; just the stable version.
	 (pulse-flag nil)
	 )
    (cond ((semantic-overlay-p region)
	   (with-current-buffer (semantic-overlay-buffer region)
	     (goto-char (semantic-overlay-start region))
	     (when (pos-visible-in-window-p
		    (point) (get-buffer-window (current-buffer) 'visible))
	       (if (< (semantic-overlay-end region) (point-at-eol))
		   (pulse-momentary-highlight-overlay
		    region semantic-idle-symbol-highlight-face)
		 ;; Not the same
		 (pulse-momentary-highlight-region
		  (semantic-overlay-start region)
		  (point-at-eol)
		  semantic-idle-symbol-highlight-face)))
	     ))
	  ((vectorp region)
	   (let ((start (aref region 0))
		 (end (aref region 1)))
	     (save-excursion
	       (when buffer (set-buffer buffer))
	       ;; As a vector, we have no filename.  Perhaps it is a
	       ;; local variable?
	       (when (and (<= end (point-max))
			  (pos-visible-in-window-p
			   start (get-buffer-window (current-buffer) 'visible)))
		 (goto-char start)
		 (when (re-search-forward
			(regexp-quote (semantic-tag-name tag))
			end t)
		   ;; This is likely it, give it a try.
		   (pulse-momentary-highlight-region
		    start (if (<= end (point-at-eol)) end
			    (point-at-eol))
		    semantic-idle-symbol-highlight-face)))
	       ))))
    nil))


(define-semantic-idle-service semantic-idle-local-symbol-highlight
  "Highlight the tag and symbol references of the symbol under point.
Call `semantic-analyze-current-context' to find the reference tag.
Call `semantic-symref-hits-in-region' to identify local references."
  (when (semantic-idle-summary-useful-context-p)
    (let* ((ctxt
	    (semanticdb-without-unloaded-file-searches
		(semantic-analyze-current-context)))
	   (Hbounds (when ctxt (oref ctxt bounds)))
	   (target (when ctxt (car (reverse (oref ctxt prefix)))))
	   (tag (semantic-current-tag))
	   ;; We use pulse, but we don't want the flashy version,
	   ;; just the stable version.
	   (pulse-flag nil))
      (when ctxt
	;; Highlight the original tag?  Protect against problems.
	(condition-case nil
	    (semantic-idle-symbol-maybe-highlight target)
	  (error nil))
	;; Identify all hits in this current tag.
	(when (semantic-tag-p target)
	  (semantic-symref-hits-in-region
	   target (lambda (start end prefix)
		    (when (/= start (car Hbounds))
		      (pulse-momentary-highlight-region
		       start end semantic-idle-symbol-highlight-face))
		    (semantic-throw-on-input 'symref-highlight)
		    )
	   (semantic-tag-start tag)
	   (semantic-tag-end tag)))
	))))


;;;###autoload
(defun global-semantic-idle-scheduler-mode (&optional arg)
  "Toggle global use of option `semantic-idle-scheduler-mode'.
The idle scheduler will automatically reparse buffers in idle time,
and then schedule other jobs setup with `semantic-idle-scheduler-add'.
If ARG is positive, enable, if it is negative, disable.
If ARG is nil, then toggle."
  (interactive "P")
  (setq global-semantic-idle-scheduler-mode
        (semantic-toggle-minor-mode-globally
         'semantic-idle-scheduler-mode arg)))


;;; Completion Popup Mode
;;
;; This mode uses tooltips to display a (hopefully) short list of possible
;; completions available for the text under point.  It provides
;; NO provision for actually filling in the values from those completions.
(defun semantic-idle-completions-end-of-symbol-p ()
  "Return non-nil if the cursor is at the END of a symbol.
If the cursor is in the middle of a symbol, then we shouldn't be
doing fancy completions."
  (not (looking-at "\\w\\|\\s_")))

(defun semantic-idle-completion-list-default ()
  "Calculate and display a list of completions."
  (when (and (semantic-idle-summary-useful-context-p)
	     (semantic-idle-completions-end-of-symbol-p))
    ;; This mode can be fragile.  Ignore problems.
    ;; If something doesn't do what you expect, run
    ;; the below command by hand instead.
    (condition-case nil
	(semanticdb-without-unloaded-file-searches
	    ;; Use idle version.
	    (semantic-complete-analyze-inline-idle)
	  )
      (error nil))
    ))

(define-semantic-idle-service semantic-idle-completions
  "Toggle Semantic Idle Completions mode.
With ARG, turn Semantic Idle Completions mode on if ARG is
positive, off otherwise.

This minor mode only takes effect if Semantic is active and
`semantic-idle-scheduler-mode' is enabled.

When enabled, Emacs displays a list of possible completions at
idle time.  The method for displaying completions is given by
`semantic-complete-inline-analyzer-idle-displayor-class'; the
default is to show completions inline.

While a completion is displayed, RET accepts the completion; M-n
and M-p cycle through completion alternatives; TAB attempts to
complete as far as possible, and cycles if no additional
completion is possible; and any other command cancels the
completion.

\\{semantic-complete-inline-map}"
  ;; Add the ability to override sometime.
  (semantic-idle-completion-list-default))


;;; Breadcrumbs for tag under point
;;
;; Service that displays a breadcrumbs indication of the tag under
;; point and its parents in the header or mode line.
;;

(defcustom semantic-idle-breadcrumbs-display-function
  #'semantic-idle-breadcrumbs--display-in-header-line
  "Specify how to display the tag under point in idle time.
This function should take a list of Semantic tags as its only
argument. The tags are sorted according to their nesting order,
starting with the outermost tag. The function should call
`semantic-idle-breadcrumbs-format-tag-list-function' to convert
the tag list into a string."
  :group 'semantic
  :type  '(choice
	   (const    :tag "Display in header line"
		     semantic-idle-breadcrumbs--display-in-header-line)
	   (const    :tag "Display in mode line"
		     semantic-idle-breadcrumbs--display-in-mode-line)
	   (function :tag "Other function")))

(defcustom semantic-idle-breadcrumbs-format-tag-list-function
  #'semantic-idle-breadcrumbs--format-linear
  "Specify how to format the list of tags containing point.
This function should take a list of Semantic tags as its only
argument. The tags are sorted according to their nesting order,
starting with the outermost tag. Single tags should be formatted
using `semantic-idle-breadcrumbs-format-tag-function' unless
special formatting is required."
  :group 'semantic
  :type  '(choice
	   (const    :tag "Format tags as list, innermost last"
		     semantic-idle-breadcrumbs--format-linear)
	   (const    :tag "Innermost tag with details, followed by remaining tags"
		     semantic-idle-breadcrumbs--format-innermost-first)
	   (function :tag "Other function")))

(defcustom semantic-idle-breadcrumbs-format-tag-function
  #'semantic-format-tag-abbreviate
  "Function to call to format information about tags.
This function should take a single argument, a Semantic tag, and
return a string to display.
Some useful functions are found in `semantic-format-tag-functions'."
   :group 'semantic
   :type  semantic-format-tag-custom-list)

(defcustom semantic-idle-breadcrumbs-separator 'mode-specific
  "Specify how to separate tags in the breadcrumbs string.
An arbitrary string or a mode-specific scope nesting
string (like, for example, \"::\" in C++, or \".\" in Java) can
be used."
  :group 'semantic
  :type  '(choice
	   (const  :tag "Use mode specific separator"
		   mode-specific)
	   (string :tag "Specify separator string")))

(defcustom semantic-idle-breadcrumbs-header-line-prefix
  semantic-stickyfunc-indent-string ;; TODO not optimal
  "String used to indent the breadcrumbs string.
Customize this string to match the space used by scrollbars and
fringe."
  :group 'semantic
  :type  'string)

(defun semantic-idle-breadcrumbs--popup-menu (event)
  "Popup a menu that displays things to do to the clicked tag.
Argument EVENT describes the event that caused this function to
be called."
  (interactive "e")
  (let ((old-window (selected-window))
	(window     (semantic-event-window event)))
    (select-window window t)
    (semantic-popup-menu semantic-idle-breadcrumbs-popup-menu)
    (select-window old-window)))

(defmacro semantic-idle-breadcrumbs--tag-function (function)
  "Return lambda expression calling FUNCTION when called from a popup."
  `(lambda (event)
     (interactive "e")
     (let* ((old-window (selected-window))
	    (window     (semantic-event-window event))
	    (column     (car (nth 6 (nth 1 event)))) ;; TODO semantic-event-column?
	    (tag        (progn
			  (select-window window t)
			  (plist-get
			   (text-properties-at column header-line-format)
			   'tag))))
       (,function tag)
       (select-window old-window)))
  )

;; TODO does this work for mode-line case?
(defvar semantic-idle-breadcrumbs-popup-map
  (let ((map (make-sparse-keymap)))
    ;; mouse-1 goes to clicked tag
    (define-key map
      [ header-line mouse-1 ]
      (semantic-idle-breadcrumbs--tag-function
       semantic-go-to-tag))
    ;; mouse-3 pops up a context menu
    (define-key map
      [ header-line mouse-3 ]
      'semantic-idle-breadcrumbs--popup-menu)
    map)
  "Keymap for semantic idle breadcrumbs minor mode.")

(defvar semantic-idle-breadcrumbs-popup-menu nil
  "Menu used when a tag displayed by `semantic-idle-breadcrumbs-mode' is clicked.")

(easy-menu-define
  semantic-idle-breadcrumbs-popup-menu
  semantic-idle-breadcrumbs-popup-map
  "Semantic Breadcrumbs Mode Menu"
  (list
   "Breadcrumb Tag"
   (senator-menu-item
    (vector
     "Go to Tag"
     (semantic-idle-breadcrumbs--tag-function
      semantic-go-to-tag)
     :active t
     :help  "Jump to this tag"))
   ;; TODO these entries need minor changes (optional tag argument) in
   ;; senator-copy-tag etc
  ;;  (senator-menu-item
  ;;   (vector
  ;;    "Copy Tag"
  ;;    (semantic-idle-breadcrumbs--tag-function
  ;;     senator-copy-tag)
  ;;    :active t
  ;;    :help   "Copy this tag"))
  ;;   (senator-menu-item
  ;;    (vector
  ;;     "Kill Tag"
  ;;     (semantic-idle-breadcrumbs--tag-function
  ;;      senator-kill-tag)
  ;;     :active t
  ;;     :help   "Kill tag text to the kill ring, and copy the tag to
  ;; the tag ring"))
  ;;   (senator-menu-item
  ;;    (vector
  ;;     "Copy Tag to Register"
  ;;     (semantic-idle-breadcrumbs--tag-function
  ;;      senator-copy-tag-to-register)
  ;;     :active t
  ;;     :help   "Copy this tag"))
  ;;   (senator-menu-item
  ;;    (vector
  ;;     "Narrow to Tag"
  ;;     (semantic-idle-breadcrumbs--tag-function
  ;;      senator-narrow-to-defun)
  ;;     :active t
  ;;     :help   "Narrow to the bounds of the current tag"))
  ;;   (senator-menu-item
  ;;    (vector
  ;;     "Fold Tag"
  ;;     (semantic-idle-breadcrumbs--tag-function
  ;;      senator-fold-tag-toggle)
  ;;     :active   t
  ;;     :style    'toggle
  ;;     :selected '(let ((tag (semantic-current-tag)))
  ;; 		   (and tag (semantic-tag-folded-p tag)))
  ;;     :help     "Fold the current tag to one line"))
    "---"
    (senator-menu-item
     (vector
      "About this Header Line"
      (lambda ()
	(interactive)
	(describe-function 'semantic-idle-breadcrumbs-mode))
      :active t
      :help   "Display help about this header line."))
    )
  )

(define-semantic-idle-service semantic-idle-breadcrumbs
  "Display breadcrumbs for the tag under point and its parents."
  (let* ((scope    (semantic-calculate-scope))
	 (tag-list (if scope
		       ;; If there is a scope, extract the tag and its
		       ;; parents.
		       (append (oref scope parents)
			       (when (oref scope tag)
				 (list (oref scope tag))))
		     ;; Fall back to tags by overlay
		     (semantic-find-tag-by-overlay))))
    ;; Display the tags.
    (funcall semantic-idle-breadcrumbs-display-function tag-list)))

(defun semantic-idle-breadcrumbs--display-in-header-line (tag-list)
  "Display the tags in TAG-LIST in the header line of their buffer."
  (let ((width (- (nth 2 (window-edges))
		  (nth 0 (window-edges)))))
    ;; Format TAG-LIST and put the formatted string into the header
    ;; line.
    (setq header-line-format
	  (concat
	   semantic-idle-breadcrumbs-header-line-prefix
	   (if tag-list
	       (semantic-idle-breadcrumbs--format-tag-list
		tag-list
		(- width
		   (length semantic-idle-breadcrumbs-header-line-prefix)))
	     (propertize
	      "<not on tags>"
	      'face
	      'font-lock-comment-face)))))

  ;; Update the header line.
  (force-mode-line-update))

(defun semantic-idle-breadcrumbs--display-in-mode-line (tag-list)
  "Display the tags in TAG-LIST in the mode line of their buffer.
TODO THIS FUNCTION DOES NOT WORK YET."

  (error "This function does not work yet")

  (let ((width (- (nth 2 (window-edges))
		  (nth 0 (window-edges)))))
    (setq mode-line-format
	  (semantic-idle-breadcrumbs--format-tag-list tag-list width)))

  (force-mode-line-update))

(defun semantic-idle-breadcrumbs--format-tag-list (tag-list max-length)
  "Format TAG-LIST using configured functions respecting MAX-LENGTH.
If the initial formatting result is longer than MAX-LENGTH, it is
shortened at the beginning."
  ;; Format TAG-LIST using the configured formatting function.
  (let* ((complete-format (funcall
			   semantic-idle-breadcrumbs-format-tag-list-function
			   tag-list))
	 ;; Determine length of complete format.
	 (complete-length (length complete-format)))
    ;; Shorten string if necessary.
    (if (<= complete-length max-length)
	complete-format
      (concat "... "
	      (substring
	       complete-format
	       (- complete-length (- max-length 4))))))
  )

(defun semantic-idle-breadcrumbs--format-linear (tag-list)
  "Format TAG-LIST ensuring the string does not get longer than MAX-LENGTH."
  (let* ((format-pieces   (mapcar
			   #'semantic-idle-breadcrumbs--format-tag
			   tag-list))
	 ;; Format tag list, putting configured separators between the
	 ;; tags.
	 (complete-format (cond
			   ;; Mode specific separator.
			   ((eq semantic-idle-breadcrumbs-separator 'mode-specific)
			    (semantic-analyze-unsplit-name format-pieces))

			   ;; Custom separator.
			   ((stringp semantic-idle-breadcrumbs-separator)
			    (mapconcat
			     #'identity
			     format-pieces
			     semantic-idle-breadcrumbs-separator)))))
    complete-format)
  )

(defun semantic-idle-breadcrumbs--format-innermost-first (tag-list)
  "Format TAG-LIST placing the innermost tag first."
  (concat (semantic-idle-breadcrumbs--format-tag
	   (car (last tag-list))
	   #'semantic-format-tag-prototype)
	  (when (butlast tag-list)
	    (concat
	     " | "
	     (semantic-idle-breadcrumbs--format-linear (butlast tag-list))
	     "")))
  )

(defun semantic-idle-breadcrumbs--format-tag (tag &optional format-function)
  "Format TAG using the configured function or FORMAT-FUNCTION.
This function also adds text properties for help-echo, mouse
highlighting and a keymap."
  (let ((formatted (funcall
		    (or format-function
			semantic-idle-breadcrumbs-format-tag-function)
		    tag nil t)))
    (add-text-properties
     0 (length formatted)
     (list
      'tag
      tag
      'help-echo
      (format
       "Tag %s
Type: %s
mouse-1: jump to tag
mouse-3: popup context menu"
       (semantic-tag-name tag)
       (semantic-tag-class tag))
      'mouse-face
      'highlight
      'keymap
      semantic-idle-breadcrumbs-popup-map)
     formatted)
    formatted))

(provide 'semantic-idle)

;;; semantic-idle.el ends here
