;;; core/cli/autoloads.el -*- lexical-binding: t; -*-

(defvar doom-autoloads-excluded-packages ()
  "What packages whose autoloads files we won't index.

These packages have silly or destructive autoload files that try to load
everyone in the universe and their dog, causing errors that make babies cry. No
one wants that.")

(defvar doom-autoloads-excluded-files
  '("/bufler/bufler-workspaces-tabs\\.el$")
  "List of regexps whose matching files won't be indexed for autoloads.")

(defvar doom-autoloads-cached-vars
  '(doom-modules
    doom-disabled-packages
    native-comp-deferred-compilation-deny-list
    load-path
    auto-mode-alist
    interpreter-mode-alist
    Info-directory-list)
  "A list of variables to be cached in `doom-autoloads-file'.")

(defvar doom-autoloads-files ()
  "A list of additional files or file globs to scan for autoloads.")


;;
;;; Library

(defun doom-autoloads-reload (&optional file)
  "Regenerates Doom's autoloads and writes them to FILE."
  (unless file
    (setq file doom-autoloads-file))
  (print! (start "(Re)generating autoloads file..."))
  (print-group!
   (cl-check-type file string)
   (doom-initialize-packages)
   (and (print! (start "Generating autoloads file..."))
        (doom-autoloads--write
         file
         `((unless (equal doom-version ,doom-version)
             (signal 'doom-error
                     (list "The installed version of Doom has changed since last 'doom sync' ran"
                           "Run 'doom sync' to bring Doom up to speed"))))
         (cl-loop for var in doom-autoloads-cached-vars
                  when (boundp var)
                  collect `(set ',var ',(symbol-value var)))
         (doom-autoloads--scan
          (append (cl-loop for dir
                           in (append (list doom-core-dir)
                                      (cdr (doom-module-load-path 'all-p))
                                      (list doom-private-dir))
                           if (doom-glob dir "autoload.el") collect (car it)
                           if (doom-glob dir "autoload/*.el") append it)
                  (mapcan #'doom-glob doom-autoloads-files))
          nil)
         (doom-autoloads--scan
          (mapcar #'straight--autoloads-file
                  (seq-difference (hash-table-keys straight--build-cache)
                                  doom-autoloads-excluded-packages))
          doom-autoloads-excluded-files
          'literal))
        (print! (start "Byte-compiling autoloads file..."))
        (doom-autoloads--compile-file file)
        (print! (success "Generated %s")
                (relpath (byte-compile-dest-file file)
                         doom-emacs-dir)))))

(defun doom-autoloads--write (file &rest forms)
  (make-directory (file-name-directory file) 'parents)
  (condition-case-unless-debug e
      (with-temp-file file
        (setq-local coding-system-for-write 'utf-8)
        (let ((standard-output (current-buffer))
              (print-quoted t)
              (print-level nil)
              (print-length nil))
          (insert ";; -*- lexical-binding: t; coding: utf-8; no-native-compile: t -*-\n"
                  ";; This file is autogenerated by 'doom sync', DO NOT EDIT IT!!\n")
          (dolist (form (delq nil forms))
            (mapc #'prin1 form))
          t))
    (error (delete-file file)
           (signal 'doom-autoload-error (list file e)))))

(defun doom-autoloads--compile-file (file)
  (condition-case-unless-debug e
      (let ((byte-compile-warnings (if doom-debug-p byte-compile-warnings)))
        (and (byte-compile-file file)
             (load (byte-compile-dest-file file) nil t)))
    (error
     (delete-file (byte-compile-dest-file file))
     (signal 'doom-autoload-error (list file e)))))

(defun doom-autoloads--cleanup-form (form &optional expand)
  (let ((func (car-safe form)))
    (cond ((memq func '(provide custom-autoload))
           nil)
          ((and (eq func 'add-to-list)
                (memq (doom-unquote (cadr form))
                      doom-autoloads-cached-vars))
           nil)
          ((not (eq func 'autoload))
           form)
          ((and expand (not (file-name-absolute-p (nth 2 form))))
           (defvar doom--autoloads-path-cache nil)
           (setf (nth 2 form)
                 (let ((path (nth 2 form)))
                   (or (cdr (assoc path doom--autoloads-path-cache))
                       (when-let* ((libpath (locate-library path))
                                   (libpath (file-name-sans-extension libpath))
                                   (libpath (abbreviate-file-name libpath)))
                         (push (cons path libpath) doom--autoloads-path-cache)
                         libpath)
                       path)))
           form)
          (form))))

(defun doom-autoloads--scan-autodefs (file buffer module &optional module-enabled-p)
  (with-temp-buffer
    (insert-file-contents file)
    (while (re-search-forward "^;;;###autodef *\\([^\n]+\\)?\n" nil t)
      (let* ((standard-output buffer)
             (form    (read (current-buffer)))
             (altform (match-string 1))
             (definer (car-safe form))
             (symbol  (doom-unquote (cadr form))))
        (cond ((and (not module-enabled-p) altform)
               (print (read altform)))
              ((memq definer '(defun defmacro cl-defun cl-defmacro))
               (if module-enabled-p
                   (print (make-autoload form file))
                 (cl-destructuring-bind (_ _ arglist &rest body) form
                   (print
                    (if altform
                        (read altform)
                      (append
                       (list (pcase definer
                               (`defun 'defmacro)
                               (`cl-defun `cl-defmacro)
                               (_ type))
                             symbol arglist
                             (format "THIS FUNCTION DOES NOTHING BECAUSE %s IS DISABLED\n\n%s"
                                     module
                                     (if (stringp (car body))
                                         (pop body)
                                       "No documentation.")))
                       (cl-loop for arg in arglist
                                if (and (symbolp arg)
                                        (not (keywordp arg))
                                        (not (memq arg cl--lambda-list-keywords)))
                                collect arg into syms
                                else if (listp arg)
                                collect (car arg) into syms
                                finally return (if syms `((ignore ,@syms)))))))))
               (print `(put ',symbol 'doom-module ',module)))
              ((eq definer 'defalias)
               (cl-destructuring-bind (_ _ target &optional docstring) form
                 (unless module-enabled-p
                   (setq target #'ignore
                         docstring
                         (format "THIS FUNCTION DOES NOTHING BECAUSE %s IS DISABLED\n\n%s"
                                 module docstring)))
                 (print `(put ',symbol 'doom-module ',module))
                 (print `(defalias ',symbol #',(doom-unquote target) ,docstring))))
              (module-enabled-p (print form)))))))

(defvar autoload-timestamps)
(defvar generated-autoload-load-name)
(defun doom-autoloads--scan-file (file)
  (let* (;; Prevent `autoload-find-file' from firing file hooks, e.g. adding
         ;; to recentf.
         find-file-hook
         write-file-functions
         ;; Prevent a possible source of crashes when there's a syntax error in
         ;; the autoloads file.
         debug-on-error
         ;; Non-nil interferes with autoload generation in Emacs < 29. See
         ;; raxod502/straight.el#904.
         (left-margin 0)
         ;; The following bindings are in `package-generate-autoloads'.
         ;; Presumably for a good reason, so I just copied them.
         (backup-inhibited t)
         (version-control 'never)
         case-fold-search    ; reduce magic
         autoload-timestamps ; reduce noise in generated files
         ;; So `autoload-generate-file-autoloads' knows where to write it
         (generated-autoload-load-name (file-name-sans-extension file))
         (target-buffer (current-buffer))
         (module (doom-module-from-path file))
         (module-enabled-p (and (or (memq (car module) '(:core :private))
                                    (doom-module-p (car module) (cdr module)))
                                (doom-file-cookie-p file "if" t))))
    (save-excursion
      (when module-enabled-p
        (quiet! (autoload-generate-file-autoloads file target-buffer)))
      (doom-autoloads--scan-autodefs
       file target-buffer module module-enabled-p))))

(defun doom-autoloads--scan (files &optional exclude literal)
  "Scan and return all autoloaded forms in FILES.

Autoloads will be generated from autoload cookies in FILES (except those that
match one of the regexps in EXCLUDE -- a list of strings). If LITERAL is
non-nil, treat FILES as pre-generated autoload files instead."
  (require 'autoload)
  (let (autoloads)
    (dolist (file files (nreverse (delq nil autoloads)))
      (when (and (not (seq-find (doom-rpartial #'string-match-p file) exclude))
                 (file-readable-p file))
        (doom-log "Scanning %s" file)
        (setq file (file-truename file))
        (with-temp-buffer
          (if literal
              (insert-file-contents file)
            (doom-autoloads--scan-file file))
          (save-excursion
            (while (re-search-forward "\\_<load-file-name\\_>" nil t)
              ;; `load-file-name' is meaningless in a concatenated
              ;; mega-autoloads file, but also essential in isolation, so we
              ;; replace references to it with the file they came from.
              (let ((ppss (save-excursion (syntax-ppss))))
                (or (nth 3 ppss)
                    (nth 4 ppss)
                    (replace-match (prin1-to-string file) t t)))))
          (let ((load-file-name file)
                (load-path
                 (append (list doom-private-dir)
                         doom-modules-dirs
                         load-path)))
            (condition-case _
                (while t
                  (push (doom-autoloads--cleanup-form (read (current-buffer))
                                                      (not literal))
                        autoloads))
              (end-of-file))))))))
