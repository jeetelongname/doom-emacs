;;; config/tutorial/autoload/tutorial.el -*- lexical-binding: t; -*-

(defvar doom-tutorial-hist-file
  (expand-file-name "tutorial-progress.el" doom-cache-dir)
  "Directory where tutorial progress information is saved.")

(defvar doom-tutorial--progress
  (when (file-exists-p doom-tutorial-hist-file)
    (with-temp-buffer
      (insert-file-contents doom-tutorial-hist-file)
      (read (current-buffer))))
  "An alist of tutorials and progress information.")

(defun doom-tutorial--save-progress ()
  "Write `doom-tutorial--progress' to `doom-tutorial-hist-file'."
  (with-temp-buffer
    (insert
     ";; -*- mode: emacs-lisp -*-\n"
     ";; Tutorial progress file, automatically generated by `doom-tutorial--save-progress'.\n"
     "\n")
    (let ((print-length nil)
          (print-level nil)
          (print-quoted t))
      (prin1 doom-tutorial--progress
             (current-buffer)))
    (insert ?\n)
    (condition-case err
        (write-region (point-min) (point-max) doom-tutorial-hist-file nil
                      (unless (called-interactively-p 'interactive) 'quiet))
      (file-error
       (lwarn '(doom-tutorial-hist-file) :warning "Error writing `%s': %s"
              doom-tutorial-hist-file (caddr err))))))

(defvar doom-tutorial--registered nil
  "An alist of registered tutorials.")

(defun doom-tutorial-run (name)
  "Run the tutorial NAME."
  (doom-tutorial-quit)
  (when-let ((tutorial (cdr (assoc name doom-tutorial--registered))))
    (eval (plist-get tutorial :setup)))
  (doom-tutorial-load-page name))

(defun doom-tutorial-run-maybe (name)
  (unless (plist-get (cdr (assoc name doom-tutorial--progress)) :skipped)
    (pcase (read-char-choice
            (format "Do you want to run the %s tutorial? (y)es/(l)ater/(n)ever: "
                    (propertize (symbol-name name) 'face 'bold))
            '(?y ?l ?n))
      (?y (doom-tutorial-run name))
      (?n (plist-put (cdr (assoc name doom-tutorial--progress)) :skipped nil)))))

(defun doom-tutorial-normalise-plist (somelist)
  (cdr (cl-reduce
        (lambda (result new)
          (if (keywordp new)
              (progn (push new result)
                     (push nil result))
            (push new (car result)))
          result)
        (nreverse somelist)
        :initial-value (list nil))))

;;;###autoload
(defmacro define-tutorial! (name &optional docstring &rest body)
  (declare (doc-string 2) (indent defun))
  (unless (stringp docstring)
    (push docstring body)
    (setq docstring nil))
  (let ((parameters (doom-tutorial-normalise-plist body)))
    (when (plist-get parameters :setup)
      (plist-put parameters :setup
                 (append (list #'progn) (plist-get parameters :setup))))
    (when (plist-get parameters :teardown)
      (plist-put parameters :teardown
                 (append (list #'progn) (plist-get parameters :teardown))))
    (when (plist-get parameters :pages)
      (plist-put parameters :pages
                 (mapcar (lambda (page)
                           (if (eq 'page (car page))
                               (eval `(doom-tutorial-page! ,@(cdr page)))
                             page))
                         (plist-get parameters :pages))))
    `(progn
       (defun ,(intern (format "doom-tutorial-%s" name)) (&optional autotriggered)
         ,docstring
         (interactive "p")
         (if autotriggered
             (doom-tutorial-run ',name)
           (doom-tutorial-run-maybe ',name)))
       (doom-tutorial-register ',name ',parameters))))

(defun doom-tutorial-register (name parameters)
  (push (cons name parameters) doom-tutorial--registered)
  (unless (assoc name doom-tutorial--progress)
    (push (list name :skipped nil :complete nil :page 0)
          doom-tutorial--progress))
  (dolist (target (plist-get parameters :triggers))
    (advice-add target :after name))
  (dolist (filepattern (plist-get parameters :file-triggers))
    (add-to-list 'doom-tutorials--file-triggers (cons (eval filepattern) name))))

;;;###autoload
(defun doom-tutorial-load-modules ()
  (let (loaded-tutorials)
    (maphash (lambda (key _plist)
               (let ((tutorial-file (doom-module-path (car key) (cdr key) "tutorial.el")))
                 (when (file-exists-p tutorial-file)
                   (push (cdr key) loaded-tutorials)
                   (load tutorial-file 'noerror 'nomessage))))
             doom-modules)
    loaded-tutorials))

(defmacro doom-tutorial-page! (&rest body)
  (let ((parameters (doom-tutorial-normalise-plist body)))
    (dolist (strparam '(:instructions :title))
      (plist-put parameters strparam
                 (if-let ((paramvalue (plist-get parameters strparam)))
                     (if (cl-every #'stringp paramvalue)
                         (apply #'concat paramvalue)
                       `(lambda () (concat ,@paramvalue)))
                   "")))
    (when-let ((test (plist-get parameters :test)))
      (plist-put parameters :test
                 (cond
                  ((functionp test) test)
                  ((consp test) `(lambda () ,@test))
                  (_ (error "Test is invalid. %S" test)))))
    `(list ,@parameters)))

(defun doom-tutorial--current-page (name)
  (plist-get (cdr (assoc name doom-tutorial--progress)) :page))

(defun doom-tutorial--set-page (name page)
  (plist-put (cdr (assoc name doom-tutorial--progress)) :page page))

(defun doom-tutorial-load-page (name &optional page)
  (let ((content (nth (or (and page
                               (doom-tutorial--set-page name page))
                          (doom-tutorial--current-page name))
                      (plist-get (cdr (assoc name doom-tutorial--registered))
                                 :pages))))
    (let ((instructions (plist-get content :instructions))
          (title (plist-get content :title)))
      (with-current-buffer doom-tutorial--instructions-buffer-name
        (with-silent-modifications
          (erase-buffer)
          (insert ?\n)
          (insert (cond
                   ((stringp instructions) instructions)
                   ((functionp instructions) (funcall instructions)))))))
    (with-current-buffer doom-tutorial--scratchpad-buffer-name
      (setq-local doom-tutorial-test (plist-get content :test)))))

(defvar doom-tutorial-workspace-name "*tutorial*")
(defvar doom-tutorial--old-windowconf nil)

(defvar doom-tutorial--scratchpad-buffer-name "*tutorial scratchpad*")
(defvar doom-tutorial--scratchpad-window nil)
(defvar doom-tutorial--instructions-buffer-name "*tutorial instructions*")
(defvar doom-tutorial--cmd-log-buffer-name "*tutorial cmd-log*")

(defun doom-tutorial-setup-3-window ()
  (if (featurep! :ui workspaces)
      (progn
        (unless (+workspace-buffer-list)
          (+workspace-delete (+workspace-current-name)))
        (+workspace-switch doom-tutorial-workspace-name t))
    (setq doom-tutorial--old-windowconf (current-window-configuration))
    (delete-other-windows)
    (switch-to-buffer (doom-fallback-buffer)))
  ;; Setup do buffer
  (setq doom-tutorial--scratchpad-window (selected-window))
  (switch-to-buffer
   (get-buffer-create doom-tutorial--scratchpad-buffer-name))
  (with-silent-modifications
    (erase-buffer))
  (fundamental-mode)
  (setq-local header-line-format
              (propertize "Scratch pad" 'face '(bold org-document-title)))
  ;; Setup instruction buffer
  (split-window nil nil 'right)
  (select-window (next-window))
  (switch-to-buffer
   (get-buffer-create doom-tutorial--instructions-buffer-name))
  (with-silent-modifications
    (erase-buffer))
  (org-mode)
  (display-line-numbers-mode -1)
  (read-only-mode 1)
  (setq-local mode-line-format "next / prev buttons (todo)")
  (setq-local header-line-format
              (propertize "Instructions" 'face '(bold org-document-title)))
  ;; Setup cmd log buffer
  (split-window nil (max window-min-height
                         (/ (window-height) 3))
                'above)
  (switch-to-buffer
   (get-buffer-create doom-tutorial--cmd-log-buffer-name))
  (with-silent-modifications
    (erase-buffer))
  (setq-local mode-line-format nil)
  (setq-local header-line-format
              (propertize "Command log" 'face '(bold org-document-title)))
  (select-window doom-tutorial--scratchpad-window))

(defun doom-tutorial-quit ()
  (interactive)
  (cond
   ((and (featurep! :ui workspaces)
         (+workspace-exists-p doom-tutorial-workspace-name))
    (+workspace/delete doom-tutorial-workspace-name))
   (doom-tutorial--old-windowconf
    (set-window-configuration doom-tutorial--old-windowconf)
    (setq doom-tutorial--old-windowconf nil)))
  (doom-tutorial--save-progress))
