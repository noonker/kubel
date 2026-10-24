;;; kubel-helm.el --- Helm porcelain for kubel -*- lexical-binding: t; -*-

;; Copyright (C) 2026, noonker

;; This file is NOT part of Emacs.

;; This  program is  free  software; you  can  redistribute it  and/or
;; modify it  under the  terms of  the GNU  General Public  License as
;; published by the Free Software  Foundation; either version 2 of the
;; License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT  ANY  WARRANTY;  without   even  the  implied  warranty  of
;; MERCHANTABILITY or FITNESS  FOR A PARTICULAR PURPOSE.   See the GNU
;; General Public License for more details.

;; You should have  received a copy of the GNU  General Public License
;; along  with  this program;  if  not,  write  to the  Free  Software
;; Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307
;; USA

;; Version: 1.0
;; Author: noonker
;; Keywords: kubernetes k8s tools processes helm
;; URL: https://github.com/abrochard/kubel
;; License: GNU General Public License >= 3
;; Package-Requires: ((kubel "1.0") (transient "0.1.0") (dash "2.12.0") (yaml-mode "0.0.14") (emacs "25.3"))

;;; Commentary:

;; Manage Helm releases from a kubel-style buffer, using the `helm' CLI.

;;; Usage:

;; M-x kubel-helm
;;
;; Lists the Helm releases of all namespaces in the current kubel
;; context.  Use `n' to restrict the list to one namespace.

;;; Shortcuts:

;; On the kubel-helm screen, place your cursor on a release
;;
;; enter => release values (C-u for all computed values)
;; v => get popup (values/manifest/notes/hooks/status/all)
;; r => history and rollback popup
;; a => upgrade popup (reuse values, values file, version, dry run, diff)
;; k => uninstall popup
;; G => helm repo update
;; C => set context
;; n => set namespace (or all namespaces)
;; f, M-n, M-p, m, u, M, U, c, $, b, q => as in kubel

;;; Code:

(require 'kubel)

(defcustom kubel-helm-program "helm"
  "Helm binary path."
  :type '(file :must-match t)
  :group 'kubel)

(defconst kubel-helm--all-namespaces "*all*"
  "Completion candidate for listing releases of all namespaces.")

(defun kubel-helm--context-args ()
  "Return the context arguments for helm."
  (unless (member kubel-context '(nil ""))
    (list "--kube-context" kubel-context)))

(defun kubel-helm--release-namespace ()
  "Return the namespace of the release under cursor."
  (let ((idx (-elem-index "NAMESPACE" (mapcar #'car (append tabulated-list-format nil)))))
    (if idx
        (aref (tabulated-list-get-entry) idx)
      kubel-namespace)))

(defun kubel-helm--exec (process-name args &optional readonly callback namespace)
  "Run helm asynchronously with ARGS in the current context.
NAMESPACE defaults to the namespace of the release under cursor.
PROCESS-NAME, READONLY and CALLBACK are as in `kubel--exec-program-async'."
  (let ((ns (or namespace (kubel-helm--release-namespace))))
    (kubel--exec-program-async process-name kubel-helm-program
                               (append (kubel-helm--context-args)
                                       (unless (member ns '(nil ""))
                                         (list "--namespace" ns)))
                               args readonly callback)))

(defun kubel-helm--command (&rest args)
  "Return the helm shell command for ARGS in the current context."
  (mapconcat #'identity
             (append (list kubel-helm-program)
                     (mapcar #'shell-quote-argument (kubel-helm--context-args))
                     args)
             " "))

(defun kubel-helm--json (&rest args)
  "Run helm synchronously with ARGS and `-o json', return the parsed output."
  (let ((out (kubel--exec-sync (apply #'kubel-helm--command (append args '("-o" "json"))))))
    (ignore-errors (json-read-from-string out))))

(defun kubel-helm--populate-list ()
  "Return the tabulated list format and entries for the helm releases."
  (let* ((releases (kubel-helm--json
                    "list"
                    (if (equal kubel-namespace "")
                        "--all-namespaces"
                      (concat "--namespace " (shell-quote-argument kubel-namespace)))))
         (entrylist (cons '("NAME" "NAMESPACE" "REVISION" "UPDATED" "STATUS" "CHART" "APP VERSION")
                          (mapcar (lambda (r)
                                    (mapcar (lambda (key)
                                              (let ((value (format "%s" (or (cdr (assoc key r)) ""))))
                                                (cond ((equal value "") "-")
                                                      ;; keep "2026-04-19 20:19:20" out of the full timestamp
                                                      ((eq key 'updated) (substring value 0 (min 19 (length value))))
                                                      (t value))))
                                            '(name namespace revision updated status chart app_version)))
                                  releases))))
    (list (kubel--get-list-format entrylist) (kubel--get-list-entries entrylist))))

(defun kubel-helm--chart-name ()
  "Return the chart name of the release under cursor, without its version."
  (let ((idx (-elem-index "CHART" (mapcar #'car (append tabulated-list-format nil)))))
    (replace-regexp-in-string "-v?[0-9]+\\(\\.[0-9]+\\)*\\([-+].*\\)?$" ""
                              (aref (tabulated-list-get-entry) idx))))

(defun kubel-helm--read-chart ()
  "Read the chart reference to upgrade the release under cursor with.
Default to the repo chart matching the chart of the release."
  (let* ((name (kubel-helm--chart-name))
         (charts (mapcar (lambda (c) (cdr (assoc 'name c))) (kubel-helm--json "search" "repo")))
         (default (-first (lambda (c) (string-suffix-p (concat "/" name) c)) charts)))
    (completing-read (format "Chart%s: " (if default (format " (default %s)" default) ""))
                     charts nil nil nil nil default)))

(defun kubel-helm-get (what &optional args)
  "Show WHAT (values, manifest, notes...) of the release under cursor.
ARGS are extra arguments."
  (let ((release (kubel--get-resource-under-cursor)))
    (kubel-helm--exec (format "kubel - helm get %s - %s" what release)
                      (append (if (equal what "status") (list "status" release) (list "get" what release))
                              args)
                      t
                      (lambda ()
                        (when (member what '("values" "manifest" "hooks" "all"))
                          (yaml-mode)
                          (view-mode))
                        (goto-char (point-min))))))

(defun kubel-helm-get-values (&optional all)
  "Show the user supplied values of the release under cursor.
With prefix argument ALL, show all the computed values."
  (interactive "P")
  (kubel-helm-get "values" (when all '("--all"))))

(defun kubel-helm-get-all-values ()
  "Show all the computed values of the release under cursor."
  (interactive)
  (kubel-helm-get "values" '("--all")))

(defun kubel-helm-get-manifest ()
  "Show the manifest of the release under cursor."
  (interactive)
  (kubel-helm-get "manifest"))

(defun kubel-helm-get-notes ()
  "Show the notes of the release under cursor."
  (interactive)
  (kubel-helm-get "notes"))

(defun kubel-helm-get-hooks ()
  "Show the hooks of the release under cursor."
  (interactive)
  (kubel-helm-get "hooks"))

(defun kubel-helm-status ()
  "Show the status of the release under cursor."
  (interactive)
  (kubel-helm-get "status"))

(defun kubel-helm-get-all ()
  "Show everything about the release under cursor."
  (interactive)
  (kubel-helm-get "all"))

(defun kubel-helm-history ()
  "Show the revision history of the release under cursor."
  (interactive)
  (let ((release (kubel--get-resource-under-cursor)))
    (kubel-helm--exec (format "kubel - helm history - %s" release)
                      (list "history" release) t)))

(defun kubel-helm--refresh-callback ()
  "Return a callback refreshing the current list buffer."
  (let ((list-buffer (current-buffer)))
    (lambda ()
      (when (buffer-live-p list-buffer)
        (with-current-buffer list-buffer (kubel-refresh))))))

(defun kubel-helm-rollback (&optional args)
  "Roll back the release under cursor to a selected revision.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-helm-history-popup)))
  (let* ((release (kubel--get-resource-under-cursor))
         (ns (kubel-helm--release-namespace))
         (revisions (mapcar (lambda (r)
                              (format "%s   %s   %s   %s"
                                      (cdr (assoc 'revision r))
                                      (cdr (assoc 'status r))
                                      (cdr (assoc 'chart r))
                                      (cdr (assoc 'description r))))
                            (reverse (kubel-helm--json "history" release
                                                       "--namespace" (shell-quote-argument ns)))))
         (revision (car (split-string (completing-read (format "Roll back %s to revision: " release)
                                                       revisions nil t)))))
    (when (or (member "--dry-run" args)
              (y-or-n-p (format "Roll back %s to revision %s? " release revision)))
      (kubel-helm--exec (format "kubel - helm rollback - %s" release)
                        (append (list "rollback" release revision) args)
                        t (kubel-helm--refresh-callback)))))

(defun kubel-helm--upgrade-args (args)
  "Return the upgrade ARGS from transient, with the reuse values default."
  (if (or (member "--reuse-values" args)
          (member "--reset-then-reuse-values" args)
          (-first (lambda (a) (string-prefix-p "--values=" a)) args))
      args
    (cons "--reuse-values" args)))

(defun kubel-helm-upgrade (&optional args)
  "Upgrade the release under cursor.
Values of the release are reused unless a values file is given.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-helm-upgrade-popup)))
  (let* ((release (kubel--get-resource-under-cursor))
         (chart (kubel-helm--read-chart))
         (args (kubel-helm--upgrade-args args)))
    (when (or (-first (lambda (a) (string-prefix-p "--dry-run" a)) args)
              (y-or-n-p (format "Upgrade %s with %s %s? " release chart (string-join args " "))))
      (kubel-helm--exec (format "kubel - helm upgrade - %s" release)
                        (append (list "upgrade" release chart) args)
                        t (kubel-helm--refresh-callback)))))

(defun kubel-helm--diff-available-p ()
  "Return non-nil if the helm-diff plugin is installed."
  (string-match-p "^diff\\b" (kubel--exec-sync (kubel-helm--command "plugin" "list") t)))

(defun kubel-helm-diff-upgrade (&optional args)
  "Show what upgrading the release under cursor would change.
Requires the helm-diff plugin.  ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-helm-upgrade-popup)))
  (unless (kubel-helm--diff-available-p)
    (user-error "The helm-diff plugin is not installed, use a dry run instead"))
  (let* ((release (kubel--get-resource-under-cursor))
         (chart (kubel-helm--read-chart))
         (args (seq-remove (lambda (a) (member a '("--atomic" "--wait")))
                           (kubel-helm--upgrade-args args))))
    (kubel-helm--exec (format "kubel - helm diff - %s" release)
                      (append (list "diff" "upgrade" release chart) args)
                      t
                      (lambda ()
                        (diff-mode)
                        (view-mode)
                        (goto-char (point-min))))))

(defun kubel-helm-uninstall (&optional args)
  "Uninstall the marked or current releases.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-helm-uninstall-popup)))
  (let ((releases (kubel--marked-or-current-items))
        (ns (kubel-helm--release-namespace)))
    (when (or (member "--dry-run" args)
              (yes-or-no-p (format "Uninstall %s? " (string-join releases ", "))))
      (kubel-helm--exec (format "kubel - helm uninstall - %s" (string-join releases ","))
                        (append (list "uninstall") releases args)
                        t (kubel-helm--refresh-callback) ns))))

(defun kubel-helm-repo-update ()
  "Update the information of the chart repositories."
  (interactive)
  (kubel--exec-program-async "kubel - helm repo update" kubel-helm-program nil
                             '("repo" "update") t))

(defun kubel-helm-set-namespace ()
  "Set the namespace to list the releases of, or all namespaces."
  (interactive)
  (let* ((namespace (completing-read "Namespace: "
                                     (cons kubel-helm--all-namespaces (kubel--list-namespace))
                                     nil nil nil nil kubel-helm--all-namespaces))
         (parent-buffer (current-buffer)))
    (with-current-buffer (clone-buffer)
      (setq kubel--parent-buffer parent-buffer)
      (setq kubel--selected-items '())
      (setq kubel-namespace (if (equal namespace kubel-helm--all-namespaces) "" namespace))
      (unless (equal kubel-namespace "")
        (kubel--add-namespace-to-history kubel-namespace))
      (switch-to-buffer (current-buffer))
      (kubel-refresh))))

;; popups

(transient-define-prefix kubel-helm-get-popup ()
  "Kubel Helm Get Menu"
  ["Actions"
   ("v" "User supplied values" kubel-helm-get-values)
   ("V" "All computed values" kubel-helm-get-all-values)
   ("m" "Manifest" kubel-helm-get-manifest)
   ("n" "Notes" kubel-helm-get-notes)
   ("h" "Hooks" kubel-helm-get-hooks)
   ("s" "Status" kubel-helm-status)
   ("a" "All" kubel-helm-get-all)])

(transient-define-prefix kubel-helm-history-popup ()
  "Kubel Helm History Menu"
  ["Arguments"
   ("-d" "Dry run" "--dry-run")
   ("-w" "Wait" "--wait")
   ("-f" "Force" "--force")]
  ["Actions"
   ("h" "History" kubel-helm-history)
   ("r" "Rollback to revision" kubel-helm-rollback)])

(transient-define-prefix kubel-helm-upgrade-popup ()
  "Kubel Helm Upgrade Menu"
  ["Arguments"
   ("-r" "Reuse values (default without values file)" "--reuse-values")
   ("-R" "Reset then reuse values" "--reset-then-reuse-values")
   ("-f" "Values file" "--values=" :reader transient-read-existing-file)
   ("-v" "Chart version" "--version=")
   ("-d" "Dry run" "--dry-run=server")
   ("-w" "Wait" "--wait")
   ("-a" "Atomic" "--atomic")]
  ["Actions"
   ("a" "Upgrade" kubel-helm-upgrade)
   ("d" "Diff (helm-diff plugin)" kubel-helm-diff-upgrade)])

(transient-define-prefix kubel-helm-uninstall-popup ()
  "Kubel Helm Uninstall Menu"
  ["Arguments"
   ("-d" "Dry run" "--dry-run")
   ("-k" "Keep history" "--keep-history")]
  ["Actions"
   ("k" "Uninstall release(s)" kubel-helm-uninstall)])

(transient-define-prefix kubel-helm-help-popup ()
  "Kubel Helm Menu"
  [["Actions"
    ("RET" "Values (C-u for all)" kubel-helm-get-values)
    ("v" "Get..." kubel-helm-get-popup)
    ("r" "History/rollback..." kubel-helm-history-popup)
    ("a" "Upgrade..." kubel-helm-upgrade-popup)
    ("k" "Uninstall..." kubel-helm-uninstall-popup)
    ("G" "Repo update" kubel-helm-repo-update)
    ("g" "Refresh" kubel-refresh)
    ("b" "Buffers" kubel-switch-to-buffer)]
   ["Settings"
    ("C" "Set context" kubel-set-context)
    ("n" "Set namespace" kubel-helm-set-namespace)]
   ["Filter"
    ("f" "Filter" kubel-set-filter)
    ("M-n" "Next highlight" kubel-jump-to-next-highlight)
    ("M-p" "Previous highlight" kubel-jump-to-previous-highlight)]
   ["Marking"
    ("m" "Mark item" kubel-mark-item)
    ("u" "Unmark item" kubel-unmark-item)
    ("M" "Mark all items" kubel-mark-all)
    ("U" "Unmark all items" kubel-unmark-all)]
   ["Utilities"
    ("c" "Copy release name" kubel-copy-resource-name)
    ("$" "Show Process buffer" kubel-show-process-buffer)]])

;; mode map
(defvar kubel-helm-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") 'kubel-helm-get-values)
    (define-key map (kbd "h") 'kubel-helm-help-popup)
    (define-key map (kbd "?") 'kubel-helm-help-popup)
    (define-key map (kbd "v") 'kubel-helm-get-popup)
    (define-key map (kbd "r") 'kubel-helm-history-popup)
    (define-key map (kbd "a") 'kubel-helm-upgrade-popup)
    (define-key map (kbd "k") 'kubel-helm-uninstall-popup)
    (define-key map (kbd "G") 'kubel-helm-repo-update)
    (define-key map (kbd "n") 'kubel-helm-set-namespace)
    (define-key map (kbd "c") 'kubel-copy-resource-name)
    ;; kubectl-only commands that don't apply to helm releases
    (dolist (key '("E" "F" "y" "s" "R" "p" "e" "!" "j" "S" "l" "I"))
      (define-key map (kbd key) 'undefined))
    map)
  "Keymap for `kubel-helm-mode'.")

(define-derived-mode kubel-helm-mode kubel-mode "Kubel-Helm"
  "Special mode for kubel Helm buffers."
  (setq kubel--buffer-prefix "kubel-helm")
  (setq kubel--populate-function #'kubel-helm--populate-list))

;;;###autoload
(defun kubel-helm (&optional namespace)
  "Invoke the kubel Helm buffer.
NAMESPACE defaults to all namespaces."
  (interactive)
  (kubel--open-in-mode #'kubel-helm-mode "releases" nil (or namespace "")))

(provide 'kubel-helm)
;;; kubel-helm.el ends here
