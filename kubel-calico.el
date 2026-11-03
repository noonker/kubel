;;; kubel-calico.el --- Calico porcelain for kubel -*- lexical-binding: t; -*-

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
;; Keywords: kubernetes k8s tools processes calico
;; URL: https://github.com/abrochard/kubel
;; License: GNU General Public License >= 3
;; Package-Requires: ((kubel "1.0") (transient "0.1.0") (dash "2.12.0") (emacs "25.3"))

;;; Commentary:

;; Manage Calico from a kubel-style buffer, using the `calicoctl' CLI with
;; its default Kubernetes API datastore.  Set DATASTORE_TYPE or use
;; /etc/calico/calicoctl.cfg to point it elsewhere.

;;; Usage:

;; M-x kubel-calico
;;
;; Lists the Calico nodes in the current kubel context.  Use `R' to switch
;; to another Calico resource.  Namespaced resources follow the namespace
;; of the buffer, an empty namespace lists all of them.

;;; Shortcuts:

;; On the kubel-calico screen, place your cursor on a resource
;;
;; enter => calicoctl get -o yaml
;; C-u enter => calicoctl get -o json
;; E => edit the resource, C-c C-c to calicoctl apply it
;; a => actions popup (ipam/version/diags/label/apply file/validate file...)
;; k => delete popup
;; R => set Calico resource
;; C, n, g, f, M-n, M-p, m, u, M, U, $, b, q => as in kubel

;;; Code:

(require 'kubel)

(defcustom kubel-calico-program "calicoctl"
  "Calicoctl binary path."
  :type '(file :must-match t)
  :group 'kubel)

(defcustom kubel-calico-allow-version-mismatch nil
  "Non-nil means pass --allow-version-mismatch to calicoctl.
Calicoctl otherwise refuses to run when its version differs from the
version of the cluster."
  :type 'boolean
  :group 'kubel)

(defconst kubel-calico--resources
  '(("nodes")
    ("ippools")
    ("ipreservations")
    ("bgpconfigurations")
    ("bgppeers")
    ("bgpfilters")
    ("felixconfigurations")
    ("kubecontrollersconfigurations")
    ("clusterinformations")
    ("tiers")
    ("globalnetworkpolicies")
    ("stagedglobalnetworkpolicies")
    ("globalnetworksets")
    ("hostendpoints")
    ("profiles")
    ("networkpolicies" . t)
    ("stagednetworkpolicies" . t)
    ("stagedkubernetesnetworkpolicies" . t)
    ("networksets" . t)
    ("workloadendpoints" . t))
  "Calico resources as (NAME . NAMESPACED).
Calicoctl fails with -n on a resource which isn't namespaced.")

(defun kubel-calico--global-args ()
  "Return the global arguments for calicoctl."
  (append
   (unless (member kubel-context '(nil ""))
     (list "--context" kubel-context))
   (when kubel-calico-allow-version-mismatch
     (list "--allow-version-mismatch"))))

(defun kubel-calico--namespaced-p ()
  "Return non-nil if the current resource is namespaced."
  (cdr (assoc kubel-resource kubel-calico--resources)))

(defun kubel-calico--exec (process-name args &optional readonly callback)
  "Run calicoctl asynchronously with ARGS in the current context.
PROCESS-NAME, READONLY and CALLBACK are as in `kubel--exec-program-async'.
Stdin is a pipe, so that it can be written to.  Return the process."
  (let ((process-connection-type nil))
    (kubel--exec-program-async process-name kubel-calico-program
                               (kubel-calico--global-args) args readonly
                               (or callback (lambda () (goto-char (point-min)))))))

(defun kubel-calico--normalize-table (body)
  "Return the table BODY in the shape `kubel--parse-body' expects.
Calicoctl ends the header with spaces, which would count as a column, and
ends tables with an empty line.  Lines are padded to the same width as
column values are found by position."
  (let* ((lines (-remove (lambda (line) (string-empty-p line))
                         (mapcar #'string-trim-right (split-string body "\n"))))
         (width (apply #'max 0 (mapcar #'length lines))))
    (mapconcat (lambda (line) (concat line (make-string (- width (length line)) ?\s) "\n"))
               lines "")))

(defun kubel-calico--name-first (entrylist)
  "Move the NAME column of ENTRYLIST first, it is used as the entry id.
With a namespace, calicoctl prints the NAMESPACE column first."
  (let ((idx (-elem-index "NAME" (car entrylist))))
    (if (member idx '(nil 0))
        entrylist
      (mapcar (lambda (row) (cons (nth idx row) (-remove-at idx row))) entrylist))))

(defun kubel-calico--list-command ()
  "Return the calicoctl shell command listing the current resource."
  (mapconcat #'shell-quote-argument
             (append (list kubel-calico-program)
                     (kubel-calico--global-args)
                     (list "get" kubel-resource)
                     (when (kubel-calico--namespaced-p)
                       (if (equal kubel-namespace "")
                           '("--all-namespaces")
                         (list "--namespace" kubel-namespace)))
                     ;; The name of workload endpoints is only part of wide
                     ;; output, while profiles get a very long labels column.
                     (unless (equal kubel-resource "profiles")
                       '("-o" "wide")))
             " "))

(defun kubel-calico--populate-list ()
  "Return the tabulated list format and entries for the current resource."
  (let* ((body (kubel--exec-sync (kubel-calico--list-command)))
         (entrylist (kubel-calico--name-first
                     (kubel--parse-body (kubel-calico--normalize-table body)))))
    (list (kubel--get-list-format entrylist) (kubel--get-list-entries entrylist))))

(defun kubel-calico--namespace-column ()
  "Return the index of the NAMESPACE column, nil if there is none."
  (-elem-index "NAMESPACE" (mapcar #'car (append tabulated-list-format nil))))

(defun kubel-calico--item-namespace (name)
  "Return the namespace of the item NAME, nil if it isn't namespaced.
Names aren't unique across namespaces, so listing all namespaces uses the
line under cursor if it is NAME, and fails if NAME is otherwise ambiguous."
  (let ((idx (kubel-calico--namespace-column)))
    (when (kubel-calico--namespaced-p)
      (if (not idx)
          kubel-namespace
        (let ((current (tabulated-list-get-entry)))
          (if (and current (equal name (kubel--get-resource-under-cursor))
                   (not (kubel--items-selected-p)))
              (aref current idx)
            (let ((namespaces (mapcar (lambda (entry) (aref (cadr entry) idx))
                                      (-filter (lambda (entry) (equal name (car entry)))
                                               tabulated-list-entries))))
              (unless (= (length namespaces) 1)
                (user-error "%s exists in several namespaces, set the namespace first" name))
              (car namespaces))))))))

(defun kubel-calico--item-args (name)
  "Return the calicoctl arguments selecting the item NAME."
  (let ((namespace (kubel-calico--item-namespace name)))
    (append (list kubel-resource name)
            (when namespace (list "--namespace" namespace)))))

(defun kubel-calico-get (&optional json)
  "Show the resource under cursor as yaml.
With prefix argument JSON, show it as json."
  (interactive "P")
  (let ((name (kubel--get-resource-under-cursor)))
    (kubel-calico--exec (format "kubel - calicoctl get - %s" name)
                        (append '("get") (kubel-calico--item-args name)
                                (list "-o" (if json "json" "yaml")))
                        t)))

(defvar kubel-calico-yaml-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") 'kubel-calico-apply-buffer)
    map)
  "Keymap for `kubel-calico-yaml-mode'.")

(define-derived-mode kubel-calico-yaml-mode kubel-yaml-editing-mode "kubel-calico/e"
  "Mode to edit a Calico resource, \\[kubel-calico-apply-buffer] to apply it.

\\{kubel-calico-yaml-mode-map}")

(defun kubel-calico-edit ()
  "Edit the resource under cursor, as there is no `calicoctl edit'."
  (interactive)
  (let ((name (kubel--get-resource-under-cursor))
        (ctx kubel-context)
        (ns kubel-namespace)
        (res kubel-resource))
    (kubel-calico--exec (format "kubel - calicoctl edit - %s" name)
                        (append '("get") (kubel-calico--item-args name) '("-o" "yaml"))
                        nil
                        (lambda ()
                          (kubel-calico-yaml-mode)
                          (setq kubel-context ctx
                                kubel-namespace ns
                                kubel-resource res)
                          (set-buffer-modified-p nil)
                          (goto-char (point-min))))))

(defun kubel-calico-apply-buffer ()
  "Apply the current buffer with calicoctl."
  (interactive)
  (when (y-or-n-p (format "Apply to context %s? " kubel-context))
    (let* ((manifest (buffer-string))
           (process (kubel-calico--exec "kubel - calicoctl apply" '("apply" "-f" "-"))))
      (process-send-string process manifest)
      (process-send-eof process))))

(defun kubel-calico-apply-file (file)
  "Apply the Calico resources of FILE."
  (interactive "fApply file: ")
  (when (y-or-n-p (format "Apply %s to context %s? " file kubel-context))
    (let ((list-buffer (current-buffer)))
      (kubel-calico--exec (format "kubel - calicoctl apply - %s" file)
                          (list "apply" "-f" (expand-file-name file))
                          nil (kubel--refresh-callback list-buffer)))))

(defun kubel-calico-validate-file (file)
  "Validate the Calico resources of FILE, without contacting the cluster."
  (interactive "fValidate file: ")
  (kubel-calico--exec (format "kubel - calicoctl validate - %s" file)
                      (list "validate" "-f" (expand-file-name file)) t))

(defun kubel-calico-delete (&optional args)
  "Delete the marked or current resources.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-calico-delete-popup)))
  (let* ((names (kubel--marked-or-current-items))
         (targets (mapcar #'kubel-calico--item-args names))
         (list-buffer (current-buffer)))
    (when (y-or-n-p (format "Delete %s %s in context %s? "
                            kubel-resource (string-join names ", ") kubel-context))
      (dolist (target targets)
        (kubel-calico--exec (format "kubel - calicoctl delete - %s" (cadr target))
                            (append '("delete") target args)
                            nil (kubel--refresh-callback list-buffer))))))

(defun kubel-calico-label (label)
  "Set LABEL on the resource under cursor.
LABEL is key=value to set a label, or key to remove it."
  (interactive "sLabel (key=value to set, key to remove): ")
  (let ((name (kubel--get-resource-under-cursor))
        (list-buffer (current-buffer)))
    (kubel-calico--exec (format "kubel - calicoctl label - %s" name)
                        (append '("label") (kubel-calico--item-args name)
                                (list label (if (string-match-p "=" label) "--overwrite" "--remove")))
                        nil (kubel--refresh-callback list-buffer))))

(defun kubel-calico-ipam-show (&optional args)
  "Show the IP usage.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-calico-popup)))
  (kubel-calico--exec "kubel - calicoctl ipam show"
                      (append '("ipam" "show")
                              (seq-filter (lambda (a) (string-match-p "\\`--\\(show-blocks\\|show-borrowed\\|show-configuration\\|ip=\\)" a))
                                          args))
                      t))

(defun kubel-calico-ipam-check (&optional args)
  "Check the integrity of the IPAM data.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-calico-popup)))
  (kubel-calico--exec "kubel - calicoctl ipam check"
                      (append '("ipam" "check")
                              (seq-filter (lambda (a) (string-match-p "\\`--\\(show-problem-ips\\|show-all-ips\\|output=\\)" a))
                                          args))
                      t))

(defun kubel-calico-ipam-release (ip)
  "Release the Calico assigned IP."
  (interactive "sRelease IP: ")
  (when (y-or-n-p (format "Release %s in context %s? " ip kubel-context))
    (kubel-calico--exec (format "kubel - calicoctl ipam release - %s" ip)
                        (list "ipam" "release" "--ip" ip) t)))

(defun kubel-calico-version ()
  "Show the versions of calicoctl and of the cluster."
  (interactive)
  (kubel-calico--exec "kubel - calicoctl version" '("version") t))

(defun kubel-calico-cluster-diags (directory)
  "Collect the cluster diagnostics into DIRECTORY."
  (interactive "DSave diagnostics in: ")
  (let ((default-directory (file-name-as-directory (expand-file-name directory))))
    (kubel-calico--exec "kubel - calicoctl cluster diags" '("cluster" "diags") t)))

(defun kubel-calico-node-status ()
  "Show the status of the Calico node of this host, not of the cluster."
  (interactive)
  (kubel-calico--exec "kubel - calicoctl node status" '("node" "status") t))

(defun kubel-calico-node-checksystem ()
  "Check that this host, not the cluster, can run a Calico node."
  (interactive)
  (kubel-calico--exec "kubel - calicoctl node checksystem" '("node" "checksystem") t))

(defun kubel-calico-set-resource ()
  "Set the Calico resource to display."
  (interactive)
  (let ((parent-buffer (current-buffer))
        (resource (completing-read "Select Calico resource: "
                                   (mapcar #'car kubel-calico--resources) nil t)))
    (with-current-buffer (clone-buffer)
      (setq kubel--parent-buffer parent-buffer)
      (setq kubel-resource resource)
      (setq kubel--selected-items '())
      (switch-to-buffer (current-buffer))
      (kubel-refresh))))

;; popups

(transient-define-prefix kubel-calico-delete-popup ()
  "Kubel Calico Delete Menu"
  ["Arguments"
   ("-s" "Skip resources which don't exist" "--skip-not-exists")]
  ["Actions"
   ("k" "Delete resource(s)" kubel-calico-delete)])

(transient-define-prefix kubel-calico-popup ()
  "Kubel Calico Menu"
  ["IPAM show arguments"
   ("-b" "Show blocks" "--show-blocks")
   ("-B" "Show borrowed" "--show-borrowed")
   ("-c" "Show configuration" "--show-configuration")
   ("-i" "Specific IP" "--ip=")]
  ["IPAM check arguments"
   ("-p" "Show problem IPs" "--show-problem-ips")
   ("-a" "Show all IPs" "--show-all-ips")
   ("-o" "Report file" "--output=")]
  [["IPAM"
    ("s" "Show" kubel-calico-ipam-show)
    ("c" "Check" kubel-calico-ipam-check)
    ("r" "Release IP" kubel-calico-ipam-release)]
   ["Cluster"
    ("v" "Version" kubel-calico-version)
    ("d" "Diagnostics" kubel-calico-cluster-diags)
    ("l" "Label resource" kubel-calico-label)]
   ["Files"
    ("A" "Apply file" kubel-calico-apply-file)
    ("V" "Validate file" kubel-calico-validate-file)]
   ["This host"
    ("n" "Node status" kubel-calico-node-status)
    ("N" "Node check system" kubel-calico-node-checksystem)]])

(transient-define-prefix kubel-calico-help-popup ()
  "Kubel Calico Menu"
  [["Actions"
    ("RET" "Get (C-u for json)" kubel-calico-get)
    ("E" "Edit" kubel-calico-edit)
    ("a" "Calico..." kubel-calico-popup)
    ("k" "Delete" kubel-calico-delete-popup)
    ("g" "Refresh" kubel-refresh)
    ("b" "Buffers" kubel-switch-to-buffer)]
   ["Settings"
    ("C" "Set context" kubel-set-context)
    ("n" "Set namespace" kubel-set-namespace)
    ("R" "Set Calico resource" kubel-calico-set-resource)]
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
(defvar kubel-calico-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") 'kubel-calico-get)
    (define-key map (kbd "h") 'kubel-calico-help-popup)
    (define-key map (kbd "?") 'kubel-calico-help-popup)
    (define-key map (kbd "R") 'kubel-calico-set-resource)
    (define-key map (kbd "E") 'kubel-calico-edit)
    (define-key map (kbd "a") 'kubel-calico-popup)
    (define-key map (kbd "k") 'kubel-calico-delete-popup)
    ;; kubectl-only commands that don't apply to calico resources
    (dolist (key '("F" "y" "s" "r" "p" "e" "!" "j" "S" "l" "c" "I"))
      (define-key map (kbd key) 'undefined))
    map)
  "Keymap for `kubel-calico-mode'.")

(define-derived-mode kubel-calico-mode kubel-mode "Kubel-Calico"
  "Special mode for kubel Calico buffers."
  (setq kubel--buffer-prefix "kubel-calico")
  (setq kubel--populate-function #'kubel-calico--populate-list))

;;;###autoload
(defun kubel-calico (&optional resource)
  "Invoke the kubel Calico buffer.
RESOURCE is one of `kubel-calico--resources', default to nodes."
  (interactive)
  (kubel--open-in-mode #'kubel-calico-mode (or resource "nodes")))

(provide 'kubel-calico)
;;; kubel-calico.el ends here
