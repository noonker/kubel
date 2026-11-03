;;; kubel-kustomize.el --- Kustomize porcelain for kubel -*- lexical-binding: t; -*-

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
;; Keywords: kubernetes k8s tools processes kustomize
;; URL: https://github.com/abrochard/kubel
;; License: GNU General Public License >= 3
;; Package-Requires: ((kubel "1.0") (transient "0.1.0") (dash "2.12.0") (emacs "26.1"))

;;; Commentary:

;; Manage the kustomizations of a directory from a kubel-style buffer, using
;; the `kustomize' CLI, and apply them to the cluster of the buffer.

;;; Usage:

;; M-x kubel-kustomize
;;
;; Prompts for a directory and lists the kustomizations below it.  Use `R'
;; to switch to another directory.

;;; Shortcuts:

;; On the kubel-kustomize screen, place your cursor on a kustomization
;;
;; enter => kustomize build
;; a => build popup (build arguments; build/apply/diff/delete/tree/to file)
;; A => apply to the cluster
;; D => diff with the cluster
;; k => delete from the cluster
;; e => open the kustomization file
;; s => edit set popup (image/namespace/name prefix/suffix/replicas/...)
;; + => edit add popup (resource/component/patch/configmap/secret/...)
;; - => edit remove popup
;; F => edit fix
;; c => create a new kustomization
;; R => set directory
;; C, g, f, M-n, M-p, m, u, M, U, $, b, q => as in kubel

;;; Code:

(require 'kubel)

(defcustom kubel-kustomize-program "kustomize"
  "Kustomize binary path."
  :type '(file :must-match t)
  :group 'kubel)

(defconst kubel-kustomize--file-names '("kustomization.yaml" "kustomization.yml" "Kustomization")
  "The kustomization file names recognized by kustomize.")

(defconst kubel-kustomize--kubectl-args '("--server-side" "--force-conflicts" "--dry-run=server")
  "Arguments of `kubel-kustomize-build-popup' which are for kubectl.")

;; listing

(defun kubel-kustomize--file (directory)
  "Return the kustomization file of DIRECTORY, nil if there is none."
  (seq-some (lambda (name)
              (let ((file (expand-file-name name directory)))
                (when (file-exists-p file) file)))
            kubel-kustomize--file-names))

(defun kubel-kustomize--field (file field)
  "Return the top level scalar FIELD of the kustomization FILE, or -."
  (with-temp-buffer
    (insert-file-contents file)
    (if (re-search-forward (format "^%s:[ \t]*\\([^ \t\n#]+\\)" (regexp-quote field)) nil t)
        (match-string 1)
      "-")))

(defun kubel-kustomize--populate-list ()
  "Return the tabulated list format and entries for the current directory."
  (let* ((root (expand-file-name kubel-resource))
         (files (kubel--directory-files-recursively
                 root
                 (lambda (file) (member (file-name-nondirectory file) kubel-kustomize--file-names))))
         (entrylist
          (cons '("PATH" "NAMESPACE" "NAME PREFIX" "NAME SUFFIX" "MODIFIED")
                (mapcar (lambda (file)
                          (list (directory-file-name
                                 (file-relative-name (file-name-directory file) root))
                                (kubel-kustomize--field file "namespace")
                                (kubel-kustomize--field file "namePrefix")
                                (kubel-kustomize--field file "nameSuffix")
                                (format-time-string "%Y-%m-%d %H:%M:%S"
                                                    (nth 5 (file-attributes file)))))
                        files))))
    (list (kubel--get-list-format entrylist) (kubel--get-list-entries entrylist))))

;; running kustomize

(defun kubel-kustomize--directory (item)
  "Return the directory of the kustomization ITEM of the list."
  (file-name-as-directory (expand-file-name item (expand-file-name kubel-resource))))

(defun kubel-kustomize--build-args (args)
  "Return the kustomize build arguments out of ARGS, from transient."
  (seq-remove (lambda (a) (member a kubel-kustomize--kubectl-args)) args))

(defun kubel-kustomize--exec (item args &optional readonly callback)
  "Run kustomize with ARGS in the directory of ITEM.
READONLY and CALLBACK are as in `kubel--exec-program-async'."
  (let ((default-directory (kubel-kustomize--directory item))
        (process-connection-type nil))
    (kubel--exec-program-async (format "kubel - kustomize %s - %s" (car args) item)
                               kubel-kustomize-program nil args readonly callback)))

(defun kubel-kustomize--build-command (item args)
  "Return the shell command building ITEM with ARGS, in the directory of ITEM."
  (format "cd %s && %s"
          (shell-quote-argument (file-local-name (kubel-kustomize--directory item)))
          (mapconcat #'shell-quote-argument
                     (append (list kubel-kustomize-program "build")
                             (kubel-kustomize--build-args args)
                             '("."))
                     " ")))

(defun kubel-kustomize--view-yaml ()
  "Show the current output buffer as read-only yaml."
  (yaml-mode)
  (view-mode)
  (goto-char (point-min)))

(defun kubel-kustomize-build (&optional args)
  "Build the marked or current kustomizations.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-kustomize-build-popup)))
  (dolist (item (kubel--marked-or-current-items))
    (kubel-kustomize--exec item
                           (append '("build") (kubel-kustomize--build-args args) '("."))
                           nil #'kubel-kustomize--view-yaml)))

(defun kubel-kustomize-build-to-file (output &optional args)
  "Write the build of the kustomization under cursor to OUTPUT.
ARGS is the arguments list from transient."
  (interactive (list (read-file-name "Write build to: ")
                     (transient-args 'kubel-kustomize-build-popup)))
  (kubel-kustomize--exec (kubel--get-resource-under-cursor)
                         (append (list "build" "-o" (file-local-name (expand-file-name output)))
                                 (kubel-kustomize--build-args args)
                                 '("."))
                         t))

(defun kubel-kustomize-tree ()
  "Show the resources of the source files of the kustomization under cursor."
  (interactive)
  (kubel-kustomize--exec (kubel--get-resource-under-cursor) '("cfg" "tree" ".") t))

(defun kubel-kustomize-apply (&optional args)
  "Build the marked or current kustomizations and apply them to the cluster.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-kustomize-build-popup)))
  (let ((items (kubel--marked-or-current-items))
        (kubectl-args (seq-filter (lambda (a) (member a kubel-kustomize--kubectl-args)) args)))
    (when (or (member "--dry-run=server" args)
              (y-or-n-p (format "Apply %s to context %s? " (string-join items ", ") kubel-context)))
      (dolist (item items)
        (kubel--exec-pipe-to-kubectl (format "kubel - kustomize apply - %s" item)
                                     (kubel-kustomize--build-command item args)
                                     (append '("apply" "-f" "-") kubectl-args))))))

(defun kubel-kustomize-diff (&optional args)
  "Diff the build of the marked or current kustomizations with the cluster.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-kustomize-build-popup)))
  (let ((kubectl-args (seq-filter (lambda (a) (member a '("--server-side" "--force-conflicts"))) args)))
    (dolist (item (kubel--marked-or-current-items))
      (with-current-buffer
          (process-buffer
           (kubel--exec-pipe-to-kubectl (format "kubel - kustomize diff - %s" item)
                                        (kubel-kustomize--build-command item args)
                                        (append '("diff" "-f" "-") kubectl-args)
                                        (lambda () (message "No differences"))))
        (diff-mode)))))

(defun kubel-kustomize-delete (&optional args)
  "Delete the resources of the marked or current kustomizations.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-kustomize-build-popup)))
  (let ((items (kubel--marked-or-current-items))
        (dry-run (member "--dry-run=server" args)))
    (when (or dry-run
              (yes-or-no-p (format "Delete all resources of %s from context %s? "
                                   (string-join items ", ") kubel-context)))
      (dolist (item items)
        (kubel--exec-pipe-to-kubectl (format "kubel - kustomize delete - %s" item)
                                     (kubel-kustomize--build-command item args)
                                     (append '("delete" "-f" "-")
                                             (when dry-run '("--dry-run=server"))))))))

;; editing

(defun kubel-kustomize-find-file ()
  "Open the kustomization file under cursor."
  (interactive)
  (find-file (kubel-kustomize--file
              (kubel-kustomize--directory (kubel--get-resource-under-cursor)))))

(defun kubel-kustomize--edit (&rest args)
  "Run kustomize edit with ARGS on the kustomization under cursor."
  (kubel-kustomize--exec (kubel--get-resource-under-cursor)
                         (cons "edit" args)
                         nil (kubel--refresh-callback (current-buffer))))

(defun kubel-kustomize-fix ()
  "Fix the missing and deprecated fields of the kustomization under cursor."
  (interactive)
  (kubel-kustomize--edit "fix"))

(defun kubel-kustomize--relative-file (prompt)
  "Read a file with PROMPT, return it relative to the kustomization under cursor."
  (let ((directory (kubel-kustomize--directory (kubel--get-resource-under-cursor))))
    (file-relative-name (read-file-name prompt directory) directory)))

(defun kubel-kustomize-set-image (image)
  "Set IMAGE, such as name=newname:tag, in the kustomization under cursor."
  (interactive "sImage (name=newname:tag): ")
  (kubel-kustomize--edit "set" "image" image))

(defun kubel-kustomize-set-namespace (namespace)
  "Set the NAMESPACE field of the kustomization under cursor."
  (interactive "sNamespace: ")
  (kubel-kustomize--edit "set" "namespace" namespace))

(defun kubel-kustomize-set-nameprefix (prefix)
  "Set the namePrefix field to PREFIX in the kustomization under cursor."
  (interactive "sName prefix: ")
  (kubel-kustomize--edit "set" "nameprefix" prefix))

(defun kubel-kustomize-set-namesuffix (suffix)
  "Set the nameSuffix field to SUFFIX in the kustomization under cursor."
  (interactive "sName suffix: ")
  (kubel-kustomize--edit "set" "namesuffix" "--" suffix))

(defun kubel-kustomize-set-replicas (replicas)
  "Set REPLICAS, such as name=3, in the kustomization under cursor."
  (interactive "sReplicas (name=count): ")
  (kubel-kustomize--edit "set" "replicas" replicas))

(defun kubel-kustomize-set-label (label)
  "Set LABEL, such as key:value, in the kustomization under cursor."
  (interactive "sLabel (key:value): ")
  (kubel-kustomize--edit "set" "label" label))

(defun kubel-kustomize-set-annotation (annotation)
  "Set ANNOTATION, such as key:value, in the kustomization under cursor."
  (interactive "sAnnotation (key:value): ")
  (kubel-kustomize--edit "set" "annotation" annotation))

(defun kubel-kustomize-add-resource ()
  "Add a resource file or directory to the kustomization under cursor."
  (interactive)
  (kubel-kustomize--edit "add" "resource" (kubel-kustomize--relative-file "Add resource: ")))

(defun kubel-kustomize-add-component ()
  "Add a component to the kustomization under cursor."
  (interactive)
  (kubel-kustomize--edit "add" "component" (kubel-kustomize--relative-file "Add component: ")))

(defun kubel-kustomize-add-patch ()
  "Add a patch file to the kustomization under cursor."
  (interactive)
  (kubel-kustomize--edit "add" "patch" "--path" (kubel-kustomize--relative-file "Add patch: ")))

(defun kubel-kustomize-add-label (label)
  "Add LABEL, such as key:value, to the kustomization under cursor."
  (interactive "sLabel (key:value): ")
  (kubel-kustomize--edit "add" "label" label))

(defun kubel-kustomize-add-annotation (annotation)
  "Add ANNOTATION, such as key:value, to the kustomization under cursor."
  (interactive "sAnnotation (key:value): ")
  (kubel-kustomize--edit "add" "annotation" annotation))

(defun kubel-kustomize--add-generator (kind)
  "Add a generator of KIND, configmap or secret, from a file.
Literal values aren't offered as they would be visible in process
listings, and would end up in the kustomization file anyway."
  (let* ((name (read-string (format "%s name: " kind)))
         (env-file (y-or-n-p "Is this an env file of key=value lines? "))
         (file (kubel-kustomize--relative-file "From file: ")))
    (kubel-kustomize--edit "add" kind name
                           (concat (if env-file "--from-env-file=" "--from-file=") file))))

(defun kubel-kustomize-add-configmap ()
  "Add a configmap generator to the kustomization under cursor."
  (interactive)
  (kubel-kustomize--add-generator "configmap"))

(defun kubel-kustomize-add-secret ()
  "Add a secret generator to the kustomization under cursor."
  (interactive)
  (kubel-kustomize--add-generator "secret"))

(defun kubel-kustomize-remove-resource (resource)
  "Remove RESOURCE, a path or a pattern, from the kustomization under cursor."
  (interactive "sRemove resource: ")
  (kubel-kustomize--edit "remove" "resource" resource))

(defun kubel-kustomize-remove-component (component)
  "Remove COMPONENT, a path or a pattern, from the kustomization under cursor."
  (interactive "sRemove component: ")
  (kubel-kustomize--edit "remove" "component" component))

(defun kubel-kustomize-remove-patch (path)
  "Remove the patch file PATH from the kustomization under cursor."
  (interactive "sRemove patch path: ")
  (kubel-kustomize--edit "remove" "patch" "--path" path))

(defun kubel-kustomize-remove-label (keys)
  "Remove the labels KEYS, comma separated, from the kustomization under cursor."
  (interactive "sRemove label keys: ")
  (kubel-kustomize--edit "remove" "label" keys))

(defun kubel-kustomize-remove-annotation (keys)
  "Remove the annotations KEYS, comma separated, from the current kustomization."
  (interactive "sRemove annotation keys: ")
  (kubel-kustomize--edit "remove" "annotation" keys))

(defun kubel-kustomize-remove-configmap (names)
  "Remove the configmaps NAMES, comma separated, from the current kustomization."
  (interactive "sRemove configmaps: ")
  (kubel-kustomize--edit "remove" "configmap" names))

(defun kubel-kustomize-remove-secret (names)
  "Remove the secrets NAMES, comma separated, from the kustomization under cursor."
  (interactive "sRemove secrets: ")
  (kubel-kustomize--edit "remove" "secret" names))

(defun kubel-kustomize-create (directory)
  "Create a kustomization in DIRECTORY, detecting the resources in there."
  (interactive "DCreate kustomization in: ")
  (let ((default-directory (file-name-as-directory (expand-file-name directory)))
        (process-connection-type nil))
    (kubel--exec-program-async "kubel - kustomize create" kubel-kustomize-program nil
                               '("create" "--autodetect" "--recursive")
                               nil (kubel--refresh-callback (current-buffer)))))

(defun kubel-kustomize-set-directory (directory)
  "List the kustomizations of DIRECTORY."
  (interactive "DList kustomizations of directory: ")
  (let ((parent-buffer (current-buffer)))
    (with-current-buffer (clone-buffer)
      (setq kubel--parent-buffer parent-buffer)
      (setq kubel-resource (abbreviate-file-name (file-name-as-directory (expand-file-name directory))))
      (setq kubel--selected-items '())
      (switch-to-buffer (current-buffer))
      (kubel-refresh))))

;; popups

(transient-define-prefix kubel-kustomize-build-popup ()
  "Kubel Kustomize Build Menu"
  ["Build arguments"
   ("-h" "Enable helm" "--enable-helm")
   ("-p" "Enable alpha plugins" "--enable-alpha-plugins")
   ("-x" "Enable exec functions, not for untrusted configs" "--enable-exec")
   ("-N" "Network for functions" "--network")
   ("-L" "Allow loading files from outside the root" "--load-restrictor=LoadRestrictionsNone")
   ("-e" "Function env variable" "--env=")
   ("-m" "Function mount" "--mount=")]
  ["Kubectl arguments"
   ("-d" "Server dry run" "--dry-run=server")
   ("-s" "Server side" "--server-side")
   ("-F" "Force conflicts" "--force-conflicts")]
  [["Build"
    ("b" "Build" kubel-kustomize-build)
    ("o" "To file" kubel-kustomize-build-to-file)
    ("t" "Tree of sources" kubel-kustomize-tree)]
   ["Cluster"
    ("A" "Apply" kubel-kustomize-apply)
    ("D" "Diff" kubel-kustomize-diff)
    ("k" "Delete" kubel-kustomize-delete)]])

(transient-define-prefix kubel-kustomize-set-popup ()
  "Kubel Kustomize Set Menu"
  ["Set"
   ("i" "Image" kubel-kustomize-set-image)
   ("n" "Namespace" kubel-kustomize-set-namespace)
   ("p" "Name prefix" kubel-kustomize-set-nameprefix)
   ("s" "Name suffix" kubel-kustomize-set-namesuffix)
   ("r" "Replicas" kubel-kustomize-set-replicas)
   ("l" "Label" kubel-kustomize-set-label)
   ("a" "Annotation" kubel-kustomize-set-annotation)])

(transient-define-prefix kubel-kustomize-add-popup ()
  "Kubel Kustomize Add Menu"
  ["Add"
   ("r" "Resource" kubel-kustomize-add-resource)
   ("c" "Component" kubel-kustomize-add-component)
   ("p" "Patch" kubel-kustomize-add-patch)
   ("m" "Configmap" kubel-kustomize-add-configmap)
   ("s" "Secret" kubel-kustomize-add-secret)
   ("l" "Label" kubel-kustomize-add-label)
   ("a" "Annotation" kubel-kustomize-add-annotation)])

(transient-define-prefix kubel-kustomize-remove-popup ()
  "Kubel Kustomize Remove Menu"
  ["Remove"
   ("r" "Resource" kubel-kustomize-remove-resource)
   ("c" "Component" kubel-kustomize-remove-component)
   ("p" "Patch" kubel-kustomize-remove-patch)
   ("m" "Configmap" kubel-kustomize-remove-configmap)
   ("s" "Secret" kubel-kustomize-remove-secret)
   ("l" "Label" kubel-kustomize-remove-label)
   ("a" "Annotation" kubel-kustomize-remove-annotation)])

(transient-define-prefix kubel-kustomize-help-popup ()
  "Kubel Kustomize Menu"
  [["Build"
    ("RET" "Build" kubel-kustomize-build)
    ("a" "Build..." kubel-kustomize-build-popup)]
   ["Cluster"
    ("A" "Apply" kubel-kustomize-apply)
    ("D" "Diff" kubel-kustomize-diff)
    ("k" "Delete" kubel-kustomize-delete)
    ("C" "Set context" kubel-set-context)]
   ["Edit"
    ("e" "Open file" kubel-kustomize-find-file)
    ("s" "Set..." kubel-kustomize-set-popup)
    ("+" "Add..." kubel-kustomize-add-popup)
    ("-" "Remove..." kubel-kustomize-remove-popup)
    ("F" "Fix" kubel-kustomize-fix)
    ("c" "Create" kubel-kustomize-create)]
   ["Settings"
    ("R" "Set directory" kubel-kustomize-set-directory)
    ("g" "Refresh" kubel-refresh)
    ("b" "Buffers" kubel-switch-to-buffer)]
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
    ("$" "Show Process buffer" kubel-show-process-buffer)]])

;; mode map
(defvar kubel-kustomize-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") 'kubel-kustomize-build)
    (define-key map (kbd "h") 'kubel-kustomize-help-popup)
    (define-key map (kbd "?") 'kubel-kustomize-help-popup)
    (define-key map (kbd "R") 'kubel-kustomize-set-directory)
    (define-key map (kbd "a") 'kubel-kustomize-build-popup)
    (define-key map (kbd "A") 'kubel-kustomize-apply)
    (define-key map (kbd "D") 'kubel-kustomize-diff)
    (define-key map (kbd "k") 'kubel-kustomize-delete)
    (define-key map (kbd "e") 'kubel-kustomize-find-file)
    (define-key map (kbd "s") 'kubel-kustomize-set-popup)
    (define-key map (kbd "+") 'kubel-kustomize-add-popup)
    (define-key map (kbd "-") 'kubel-kustomize-remove-popup)
    (define-key map (kbd "F") 'kubel-kustomize-fix)
    (define-key map (kbd "c") 'kubel-kustomize-create)
    ;; kubectl-only commands that don't apply to files
    (dolist (key '("n" "y" "r" "p" "E" "!" "j" "S" "l" "I"))
      (define-key map (kbd key) 'undefined))
    map)
  "Keymap for `kubel-kustomize-mode'.")

(define-derived-mode kubel-kustomize-mode kubel-mode "Kubel-Kustomize"
  "Special mode for kubel Kustomize buffers."
  (setq kubel--buffer-prefix "kubel-kustomize")
  (setq kubel--populate-function #'kubel-kustomize--populate-list))

;;;###autoload
(defun kubel-kustomize (directory)
  "Invoke the kubel Kustomize buffer, listing the kustomizations of DIRECTORY."
  (interactive "DList kustomizations of directory: ")
  (kubel--open-in-mode #'kubel-kustomize-mode
                       (abbreviate-file-name (file-name-as-directory (expand-file-name directory)))
                       nil ""))

(provide 'kubel-kustomize)
;;; kubel-kustomize.el ends here
