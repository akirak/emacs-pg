;;; play.el --- Manage sandboxes for alternative configurations -*- lexical-binding: t -*-

;; Copyright (C) 2018 by Akira Komamura

;; Author: Akira Komamura <akira.komamura@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "24.4"))
;; Keywords: maint
;; URL: https://github.com/akirak/play.el

;; This file is not part of GNU Emacs.

;;; License:

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Play.el (Play) is a playground for Emacs. Its basic idea is to create
;; an isolated directory called a sandbox and make it $HOME of Emacs.
;; Play allows you to easily experiment with various Emacs configuration
;; repositories available on GitHub, while keeping your current configuration
;; untouched (almost, except for a stuff for Play). It can also simplify
;; your workflow in Emacs by hiding irrelevant files and directories
;; existing in your home directory.

;;; Code:

(require 'cl-lib)

(defconst play-original-home-directory (concat "~" user-login-name)
  "The original home directory of the user.")

(defcustom play-script-directory
  (expand-file-name ".local/bin" play-original-home-directory)
  "The directory where the wrapper script is saved."
  :group 'play)

(defcustom play-directory
  (expand-file-name ".emacs-play" play-original-home-directory)
  "The directory where home directories of play are stored."
  :group 'play)

(defcustom play-inherited-contents '(".gnupg")
  "Files and directories in the home directory that should be added to virtual home directories."
  :group 'play)

(defcustom play-dotemacs-list
      '(
        (:repo "https://github.com/bbatsov/prelude.git" :name "prelude")
        (:repo "https://github.com/seagle0128/.emacs.d.git")
        (:repo "https://github.com/purcell/emacs.d.git")
        (:repo "https://github.com/syl20bnr/spacemacs.git" :name "spacemacs")
        (:repo "https://github.com/eschulte/emacs24-starter-kit.git" :name "emacs24-starter-kit")
        (:repo "https://github.com/akirak/emacs.d.git")
        )
      "List of configuration repositories suggested in ‘play-checkout’."
      :group 'play)

(defun play--emacs-executable ()
  "Get the executable file of Emacs."
  (executable-find (car command-line-args)))

(defun play--script-paths ()
  "A list of script files generated by `play-persist' command."
  (let ((dir play-script-directory)
        (original-name (file-name-nondirectory (play--emacs-executable))))
    (mapcar (lambda (filename) (expand-file-name filename dir))
            (list original-name (concat original-name "-noplay")))))

(defun play--read-url (prompt)
  "Read a repository URL from the minibuffer, prompting with a string PROMPT."
  (read-from-minibuffer prompt))

(defun play--update-symlinks (dest)
  "Produce missing symbolic links in the sandbox directory DEST."
  (let ((origin play-original-home-directory))
    (cl-loop for relpath in play-inherited-contents
             do (let ((src (expand-file-name relpath origin))
                      (new (expand-file-name relpath dest)))
                  (when (and (not (file-exists-p new))
                             (file-exists-p src))
                    (make-directory (file-name-directory new) t)
                    (make-symbolic-link src new))
                  ))))

(defconst play--github-repo-path-pattern
  "\\(?:[0-9a-z][-0-9a-z]+/[-a-z0-9_.]+?[0-9a-z]\\)"
  "A regular expression for a repository path (user/repo) on GitHub.")

(defconst play--github-repo-url-patterns
  "A list of regular expressions that match a repository URL on GitHub."
  (list (concat "^git@github\.com:\\("
                play--github-repo-path-pattern
                "\\)\\(?:\.git\\)$")
        (concat "^https://github\.com/\\("
                play--github-repo-path-pattern
                "\\)\\(\.git\\)?$")))

(defun play--github-repo-path-p (path)
  "Check if PATH is a repository path (user/repo) on GitHub."
  (let ((case-fold-search t))
    (string-match-p (concat "^" play--github-repo-path-pattern "$") path)))

(defun play--parse-github-url (url)
  "Return a repository path (user/repo) if URL is a repository URL on GitHub."
  (cl-loop for pattern in play--github-repo-url-patterns
           when (string-match pattern url)
           return (match-string 1 url)))

(defun play--github-repo-path-to-https-url (path)
  "Convert a GitHub repository PATH into a HTTPS url."
  (concat "https://github.com/" path ".git"))

(defun play--build-name-from-url (url)
  "Produce a sandbox name from a repository URL."
  (pcase (play--parse-github-url url)
    (`nil "")
    (rpath (car (split-string rpath "/")))))

(defun play--directory (name)
  "Get the path of a sandbox named NAME."
  (expand-file-name name play-directory))

;;;###autoload
(defun play-update-symlinks ()
  "Update missing symbolic links in existing local sandboxes."
  (interactive)
  (mapc #'play--update-symlinks
        (directory-files play-directory t "^\[^.\]")))

(defvar play-last-config-home nil
  "Path to the sandbox last run.")

(defun play--process-buffer-name (name)
  "Generate the name of a buffer for a sandbox named NAME."
  (format "*play %s*" name))

(defun play--start (name home)
  "Start a sandbox named NAME at HOME."
  ;; Fail if Emacs is not run inside a window system
  (unless window-system
    (error "Can't start another Emacs as you are not using a window system"))

  (let ((process-environment (cons (concat "HOME=" home)
                                   process-environment))
        ;; Convert default-directory to full-path so Play can be run on cask
        (default-directory (expand-file-name default-directory)))
    (start-process "play"
                   (play--process-buffer-name name)
                   (play--emacs-executable))
    (setq play-last-config-home home)))

;; TODO: Add support for Helm
(defun play--config-selector (prompt installed available-alist)
  "Run ‘completing-read’ to select a sandbox to check out.

- PROMPT is a prompt displayed in the minibuffer.
- INSTALLED is a list of sandbox named which are already available locally.
- AVAILABLE-ALIST is an alist of sandboxes, which is usually taken from
  `play-dotemacs-alist'."
  (completing-read prompt
                   (cl-remove-duplicates (append installed
                                              (mapcar 'car available-alist))
                                      :test 'equal)))

(defun play--select-config (available-alist)
  "Select a sandbox to check out from either pre-configurations or a URL.

AVAILABLE-ALIST is an alist of dotemacs configurations, which is usually
taken from play-dotemacs-alist."
  (let* ((installed-list (directory-files play-directory nil "^\[^.\]"))
         (inp (play--config-selector "Choose a configuration or enter a repository URL: "
                                     installed-list available-alist))
         (installed (member inp installed-list))
         (available (assoc inp available-alist)))
    (cond
     (installed (let ((name inp))
                  (play--start name (play--directory name))))
     (available (apply 'play--start-with-dotemacs available))
     ((play--git-url-p inp) (let ((name (read-from-minibuffer "Name for the config: "
                                                              (play--build-name-from-url inp))))
                              (play--start-with-dotemacs name :repo inp)))
     (t (error (format "Doesn't look like a repository URL: %s" inp))))))

(defun play--git-url-p (s)
  "Test if S is a URL to a Git repository."
  (or (string-match-p "^\\(?:ssh|rsync|git|https?|file\\)://.+\.git/?$" s)
      (string-match-p "^\\(?:[-.a-zA-Z1-9]+@\\)?[-./a-zA-Z1-9]+:[-./a-zA-Z1-9]+\.git/?$" s)
      (string-match-p (concat "^https://github.com/"
                              play--github-repo-path-pattern) s)
      (and (string-suffix-p ".git" s) (file-directory-p s)) ; local bare repository
      (and (file-directory-p s) (file-directory-p (expand-file-name ".git" s))) ; local working tree
      ))

(cl-defun play--initialize-sandbox (name url
                                         &key
                                         (recursive t)
                                         (depth 1))
  "Initialize a sandbox with a configuration repository."
  (let ((dpath (play--directory name)))
    (condition-case err
        (progn
          (make-directory dpath t)
          (apply 'process-lines
                 (remove nil (list "git" "clone"
                                   (when recursive "--recursive")
                                   (when depth
                                     (concat "--depth="
                                             (cond ((stringp depth) depth)
                                                   ((numberp depth) (int-to-string depth)))))
                                   url
                                   (expand-file-name ".emacs.d" dpath)))
                 )
          (play--update-symlinks dpath)
          dpath)
      (error (progn (message (format "Cleaning up %s..." dpath))
                    (delete-directory dpath t)
                    (error (error-message-string err)))))))

(cl-defun play--start-with-dotemacs (name
                                     &rest other-props
                                     &key repo &allow-other-keys)
  "Start Emacs on a sandbox named NAME."
  (when (null repo)
    (error "You must pass :repo to play--start-with-dotemacs function"))
  (let ((url (if (play--github-repo-path-p repo)
                 (play--github-repo-path-to-https-url repo)
               repo)))
    (play--start name
                 (apply 'play--initialize-sandbox
                        name url
                        (cl-remprop 'repo other-props)))))

;;;###autoload
(defun play-checkout (&optional name)
  "Start Emacs on a sandbox.

If NAME is given, check out the sandbox from play-dotemacs-alist."
  (interactive)

  (make-directory play-directory t)

  (pcase (and name (play--directory name))

    ;; NAME refers to an existing sandbox
    (`(and (pred file-directory-p)
           ,dpath)
     (play--start name dpath))

    ;; Otherwise
    (`nil
     ;; Build an alist from play-dotemacs-list
     (let ((alist (cl-loop for plist in play-dotemacs-list
                           collect (cons (or (plist-get plist :name)
                                             (play--build-name-from-url (plist-get plist :repo)))
                                         plist))))
       (if (null name)
           (play--select-config alist)
         (pcase (assoc name alist)
           (`nil (error (format "Config named %s does not exist in play-dotemacs-list"
                                name)))
           (pair (apply 'play--start-with-dotemacs pair))))))))

;;;###autoload
(defun play-start-last ()
  "Start Emacs on the last sandbox run by Play."
  (interactive)
  (pcase (and (boundp 'play-last-config-home)
              play-last-config-home)
    (`nil (error "Play has not been run yet. Run 'play-checkout'"))
    (home (let* ((name (file-name-nondirectory home))
                 (proc (get-buffer-process (play--process-buffer-name name))))
            (if (and proc (process-live-p proc))
                (when (yes-or-no-p (format "%s is still running. Kill it? " name))
                  (lexical-let ((sentinel (lambda (_ event)
                                            (cond
                                             ((string-prefix-p "killed" event) (play--start name home))))))
                    (set-process-sentinel proc sentinel)
                    (kill-process proc)))
              (play--start name home))))))

;;;###autoload
(defun play-persist ()
  "Generate wrapper scripts to make the last sandbox environment the default."
  (interactive)

  (unless (boundp 'play-last-config-home)
    (error "No play instance has been run yet"))

  (let ((home play-last-config-home))
    (when (yes-or-no-p (format "Set $HOME of Emacs to %s? " home))
      (destructuring-bind
          (wrapper unwrapper) (play--script-paths)
        (play--generate-runner wrapper home)
        (play--generate-runner unwrapper play-original-home-directory)
        (message (format "%s now starts with %s as $HOME. Use %s to start normally"
                         (file-name-nondirectory wrapper)
                         home
                         (file-name-nondirectory unwrapper)))))))

(defun play--generate-runner (fpath home)
  "Generate an executable script at FPATH for running Emacs on HOME."
  (with-temp-file fpath
    (insert (concat "#!/bin/sh\n"
                    (format "HOME=%s exec %s \"$@\""
                            home
                            (play--emacs-executable)))))
  (set-file-modes fpath #o744))

;;;###autoload
(defun play-return ()
  "Delete wrapper scripts generated by Play."
  (interactive)
  (when (yes-or-no-p "Delete the scripts created by play? ")
    (mapc 'delete-file (cl-remove-if-not 'file-exists-p (play--script-paths)))))

(provide 'play)

;;; play.el ends here
