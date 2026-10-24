;;; kubel-talos.el --- Talos Linux porcelain for kubel -*- lexical-binding: t; -*-

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
;; Keywords: kubernetes k8s tools processes talos
;; URL: https://github.com/abrochard/kubel
;; License: GNU General Public License >= 3
;; Package-Requires: ((kubel "1.0") (transient "0.1.0") (dash "2.12.0") (emacs "25.3"))

;;; Commentary:

;; Manage Talos Linux nodes from a kubel-style buffer, using the
;; `talosctl' CLI.  In kubel-talos buffers, the context is the talosctl
;; context and the namespace is the list of target nodes (empty to use
;; the nodes of the talosconfig).

;;; Usage:

;; M-x kubel-talos
;;
;; Lists the services of the nodes of the current talosctl context.  Use
;; `R' to switch to containers, processes or any Talos resource
;; (as listed by `talosctl get rd').

;;; Shortcuts:

;; On the kubel-talos screen, place your cursor on a resource
;;
;; enter => resource details (service status, resource yaml)
;; C-u enter => resource as json
;; a => node popup (dashboard/health/dmesg/reboot/shutdown/...)
;; l => log popup
;; S => service popup (start/stop/restart)
;; C => set talosctl context
;; n => set nodes
;; R => set Talos resource
;; K => set talosconfig file
;; f, M-n, M-p, m, u, M, U, c, $, b, q => as in kubel

;;; Code:

(require 'kubel)

(defcustom kubel-talos-program "talosctl"
  "Talosctl binary path."
  :type '(file :must-match t)
  :group 'kubel)

(defconst kubel-talos--pseudo-resources
  '(("services" "services" "SERVICE")
    ("containers" "containers" "ID")
    ("k8s-containers" "containers -k" "ID")
    ("processes" "processes" "PID"))
  "Views that aren't `talosctl get' resources, as (NAME COMMAND ID-COLUMN).")

(defvar kubel-talos-nodes-history '()
  "List of previously used nodes.")

(defvar-local kubel-talos--resource-list-cached nil)

(defun kubel-talos--global-args ()
  "Return the context and nodes arguments for talosctl."
  (append
   (unless (member kubel-context '(nil ""))
     (list "--context" kubel-context))
   (unless (member kubel-namespace '(nil ""))
     (list "--nodes" kubel-namespace))))

(defun kubel-talos--command (&rest args)
  "Return the talosctl shell command for ARGS in the current context and nodes."
  (mapconcat #'identity
             (append (list kubel-talos-program)
                     (mapcar #'shell-quote-argument (kubel-talos--global-args))
                     args)
             " "))

(defun kubel-talos--exec (process-name args &optional readonly callback)
  "Run talosctl asynchronously with ARGS in the current context and nodes.
PROCESS-NAME, READONLY and CALLBACK are as in `kubel--exec-program-async'."
  (kubel--exec-program-async process-name kubel-talos-program
                             (kubel-talos--global-args) args readonly callback))

(defun kubel-talos--init-context ()
  "Initialize the talosctl context from the talosconfig."
  (unless kubel-context
    (setq kubel-context
          (ignore-errors
            (cdr (assoc 'context
                        (json-read-from-string
                         (kubel--exec-sync
                          (format "%s config info -o json" kubel-talos-program)))))))
    (setq kubel-namespace "")))

(defun kubel-talos--move-column-to-front (entrylist column)
  "Move COLUMN of ENTRYLIST first so it's used as the entry id.
Tree decorations such as \"└─ \" are stripped from the column values."
  (let ((idx (-elem-index column (car entrylist))))
    (if (or (null idx) (= idx 0))
        entrylist
      (mapcar (lambda (row)
                (let ((value (replace-regexp-in-string "^[└├│─ ]+" "" (or (nth idx row) ""))))
                  (cons (if (equal value "") "-" value) (-remove-at idx row))))
              entrylist))))

(defun kubel-talos--populate-list ()
  "Return the tabulated list format and entries for the current talos resource."
  (let* ((pseudo (assoc kubel-resource kubel-talos--pseudo-resources))
         (body (kubel--exec-sync
                (kubel-talos--command
                 (if pseudo (nth 1 pseudo) (concat "get " (shell-quote-argument kubel-resource))))))
         (entrylist (kubel-talos--move-column-to-front
                     (kubel--parse-body body)
                     (if pseudo (nth 2 pseudo) "ID"))))
    (list (kubel--get-list-format entrylist) (kubel--get-list-entries entrylist))))

(defun kubel-talos--column-under-cursor (column)
  "Return the value of COLUMN for the entry under cursor, nil if there is none."
  (let ((idx (-elem-index column (mapcar #'car (append tabulated-list-format nil)))))
    (when idx
      (aref (tabulated-list-get-entry) idx))))

(defun kubel-talos--node-args ()
  "Return the nodes arguments to target the node of the entry under cursor.
Fall back on the buffer nodes if the entry has no node."
  (let ((node (kubel-talos--column-under-cursor "NODE")))
    (when node (list "--nodes" node))))

(defun kubel-talos--exec-on-node (process-name args &optional readonly callback)
  "Like `kubel-talos--exec' but target the node of the entry under cursor.
PROCESS-NAME, ARGS, READONLY and CALLBACK are as in `kubel-talos--exec'."
  (kubel--exec-program-async process-name kubel-talos-program
                             (append (unless (member kubel-context '(nil ""))
                                       (list "--context" kubel-context))
                                     (or (kubel-talos--node-args)
                                         (unless (member kubel-namespace '(nil ""))
                                           (list "--nodes" kubel-namespace))))
                             args readonly callback))

(defun kubel-talos--services ()
  "List the service ids of the current nodes."
  (-distinct
   (mapcar #'car (cdr (kubel-talos--move-column-to-front
                       (kubel--parse-body (kubel--exec-sync (kubel-talos--command "services")))
                       "SERVICE")))))

(defun kubel-talos--select-service ()
  "Return the service under cursor in services view, otherwise prompt."
  (if (equal kubel-resource "services")
      (kubel--get-resource-under-cursor)
    (completing-read "Service: " (kubel-talos--services))))

(defun kubel-talos-get-resource-details (&optional json)
  "Show the details of the resource under cursor.
With prefix argument JSON, show resources as json instead of yaml."
  (interactive "P")
  (let ((id (kubel--get-resource-under-cursor))
        (callback (lambda () (goto-char (point-min)))))
    (pcase kubel-resource
      ("services"
       (kubel-talos--exec-on-node (format "kubel - talos service - %s" id)
                                  (list "service" id) t callback))
      ((or "containers" "k8s-containers")
       (kubel-talos-logs nil))
      ("processes"
       (message "%s" (kubel-talos--column-under-cursor "COMMAND")))
      (_
       (kubel-talos--exec-on-node
        (format "kubel - talos get - %s/%s" kubel-resource id)
        (append (list "get" kubel-resource id "-o" (if json "json" "yaml"))
                (let ((ns (kubel-talos--column-under-cursor "NAMESPACE")))
                  (when ns (list "--namespace" ns))))
        t
        (lambda ()
          (unless json (yaml-mode))
          (goto-char (point-min))))))))

(defun kubel-talos-logs (&optional args)
  "Show the logs of the service or container under cursor.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-talos-log-popup)))
  (let* ((container-view (member kubel-resource '("containers" "k8s-containers")))
         (id (if container-view
                 (kubel--get-resource-under-cursor)
               (kubel-talos--select-service))))
    (kubel-talos--exec-on-node (format "kubel - talos logs - %s" id)
                               (append (list "logs" id)
                                       (when (equal kubel-resource "k8s-containers") '("-k"))
                                       args)
                               t)))

(defun kubel-talos--service-action (action)
  "Run service ACTION on the service under cursor, then refresh."
  (let ((service (kubel-talos--select-service))
        (list-buffer (current-buffer)))
    (when (y-or-n-p (format "%s service %s? " (capitalize action) service))
      (kubel-talos--exec-on-node (format "kubel - talos service %s - %s" action service)
                                 (list "service" service action) t
                                 (lambda ()
                                   (when (buffer-live-p list-buffer)
                                     (with-current-buffer list-buffer (kubel-refresh))))))))

(defun kubel-talos-service-start ()
  "Start the service under cursor."
  (interactive)
  (kubel-talos--service-action "start"))

(defun kubel-talos-service-stop ()
  "Stop the service under cursor."
  (interactive)
  (kubel-talos--service-action "stop"))

(defun kubel-talos-service-restart ()
  "Restart the service under cursor."
  (interactive)
  (kubel-talos--service-action "restart"))

(defun kubel-talos-dashboard ()
  "Open the Talos dashboard of the current nodes."
  (interactive)
  (kubel--run-in-term (format "kubel-talos:%s:%s:dashboard" kubel-context kubel-namespace)
                      kubel-talos-program
                      (append (kubel-talos--global-args) '("dashboard"))))

(defun kubel-talos-health ()
  "Check the cluster health."
  (interactive)
  (kubel-talos--exec "kubel - talos health" '("health") t))

(defun kubel-talos-dmesg (&optional args)
  "Show the kernel logs of the current nodes.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-talos-node-popup)))
  (kubel-talos--exec "kubel - talos dmesg"
                     (append '("dmesg") (seq-intersection args '("--follow")))
                     t))

(defun kubel-talos-events ()
  "Stream the runtime events of the current nodes, starting with the last 100."
  (interactive)
  (kubel-talos--exec "kubel - talos events" '("events" "--tail=100") t))

(defun kubel-talos--info (process-name &rest args)
  "Show the output of talosctl ARGS in a buffer for PROCESS-NAME."
  (kubel-talos--exec process-name args t (lambda () (goto-char (point-min)))))

(defun kubel-talos-version ()
  "Show the Talos client and server versions."
  (interactive)
  (kubel-talos--info "kubel - talos version" "version"))

(defun kubel-talos-memory ()
  "Show the memory usage of the current nodes."
  (interactive)
  (kubel-talos--info "kubel - talos memory" "memory"))

(defun kubel-talos-mounts ()
  "Show the mounts of the current nodes."
  (interactive)
  (kubel-talos--info "kubel - talos mounts" "mounts"))

(defun kubel-talos-etcd-members ()
  "Show the etcd members."
  (interactive)
  (kubel-talos--info "kubel - talos etcd members" "etcd" "members"))

(defun kubel-talos-etcd-status ()
  "Show the etcd status."
  (interactive)
  (kubel-talos--info "kubel - talos etcd status" "etcd" "status"))

(defun kubel-talos--target-nodes ()
  "Return a description of the nodes targeted by the buffer."
  (if (member kubel-namespace '(nil ""))
      (format "the default nodes of context %s" kubel-context)
    kubel-namespace))

(defun kubel-talos-reboot ()
  "Reboot the current nodes."
  (interactive)
  (when (yes-or-no-p (format "Reboot %s? " (kubel-talos--target-nodes)))
    (kubel-talos--exec "kubel - talos reboot" '("reboot") t)))

(defun kubel-talos-shutdown ()
  "Shutdown the current nodes."
  (interactive)
  (when (yes-or-no-p (format "Shutdown %s? " (kubel-talos--target-nodes)))
    (kubel-talos--exec "kubel - talos shutdown" '("shutdown") t)))

(defun kubel-talos--clone-and-refresh (fn)
  "Clone the buffer, call FN in the clone, then refresh it."
  (let ((parent-buffer (current-buffer)))
    (with-current-buffer (clone-buffer)
      (setq kubel--parent-buffer parent-buffer)
      (setq kubel--selected-items '())
      (funcall fn)
      (switch-to-buffer (current-buffer))
      (kubel-refresh))))

(defun kubel-talos-set-context ()
  "Set the talosctl context."
  (interactive)
  (let* ((contexts (kubel--parse-body
                    (kubel--exec-sync (format "%s config contexts" kubel-talos-program))))
         (idx (or (-elem-index "NAME" (car contexts)) 1))
         (context (completing-read "Select talos context: "
                                   (mapcar (lambda (row) (nth idx row)) (cdr contexts)))))
    (kubel-talos--clone-and-refresh
     (lambda ()
       (setq kubel-context context)
       (setq kubel-namespace "")
       (setq kubel-talos--resource-list-cached nil)))))

(defun kubel-talos--list-nodes ()
  "List the node addresses of the cluster, falling back on the history."
  (delete-dups
   (append kubel-talos-nodes-history
           (split-string (kubel--exec-sync
                          (kubel-talos--command "get members -o jsonpath='{.spec.addresses[*]}'")
                          t)
                         "\n" t))))

(defun kubel-talos-set-nodes ()
  "Set the target nodes, comma separated.  Empty to use the talosconfig ones."
  (interactive)
  (let ((nodes (completing-read "Nodes (empty for default): " (kubel-talos--list-nodes))))
    (unless (or (equal nodes "") (member nodes kubel-talos-nodes-history))
      (push nodes kubel-talos-nodes-history))
    (kubel-talos--clone-and-refresh
     (lambda () (setq kubel-namespace nodes)))))

(defun kubel-talos--resource-list ()
  "List the available Talos resources, from cache if possible."
  (or kubel-talos--resource-list-cached
      (setq kubel-talos--resource-list-cached
            (append (mapcar #'car kubel-talos--pseudo-resources)
                    (-distinct
                     (split-string (kubel--exec-sync
                                    (kubel-talos--command "get rd -o jsonpath='{.metadata.id}'"))
                                   "\n" t))))))

(defun kubel-talos-set-resource (&optional refresh)
  "Set the Talos resource to display.
If called with a prefix argument REFRESH, refreshes the cached resource list."
  (interactive "P")
  (when refresh (setq kubel-talos--resource-list-cached nil))
  (let ((resource (completing-read "Select talos resource: " (kubel-talos--resource-list))))
    (kubel-talos--clone-and-refresh
     (lambda () (setq kubel-resource resource)))))

(defun kubel-talos-set-config-file (configfile)
  "Set the path to the talosctl CONFIGFILE."
  (interactive "f")
  (if (file-exists-p (expand-file-name configfile))
      (setenv "TALOSCONFIG" (expand-file-name configfile))
    (error "Talos config file '%s' does not exist!" configfile)))

;; popups

(transient-define-prefix kubel-talos-log-popup ()
  "Kubel Talos Log Menu"
  ["Arguments"
   ("-f" "Follow" "--follow")
   ("-n" "Tail" "--tail=")]
  ["Actions"
   ("l" "Service/container logs" kubel-talos-logs)])

(transient-define-prefix kubel-talos-service-popup ()
  "Kubel Talos Service Menu"
  ["Actions"
   ("s" "Start" kubel-talos-service-start)
   ("S" "Stop" kubel-talos-service-stop)
   ("r" "Restart" kubel-talos-service-restart)])

(transient-define-prefix kubel-talos-node-popup ()
  "Kubel Talos Node Menu"
  ["Arguments"
   ("-f" "Follow dmesg" "--follow")]
  [["Observe"
    ("d" "Dashboard" kubel-talos-dashboard)
    ("h" "Health" kubel-talos-health)
    ("k" "Kernel logs (dmesg)" kubel-talos-dmesg)
    ("e" "Events" kubel-talos-events)]
   ["Info"
    ("v" "Version" kubel-talos-version)
    ("m" "Memory" kubel-talos-memory)
    ("M" "Mounts" kubel-talos-mounts)
    ("t" "Etcd members" kubel-talos-etcd-members)
    ("T" "Etcd status" kubel-talos-etcd-status)]
   ["Power"
    ("R" "Reboot" kubel-talos-reboot)
    ("X" "Shutdown" kubel-talos-shutdown)]])

(transient-define-prefix kubel-talos-help-popup ()
  "Kubel Talos Menu"
  [["Actions"
    ("RET" "Resource details" kubel-talos-get-resource-details)
    ("a" "Node..." kubel-talos-node-popup)
    ("l" "Logs" kubel-talos-log-popup)
    ("S" "Service..." kubel-talos-service-popup)
    ("g" "Refresh" kubel-refresh)
    ("b" "Buffers" kubel-switch-to-buffer)]
   ["Settings"
    ("C" "Set talos context" kubel-talos-set-context)
    ("n" "Set nodes" kubel-talos-set-nodes)
    ("R" "Set talos resource" kubel-talos-set-resource)
    ("K" "Set talosconfig file" kubel-talos-set-config-file)]
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
    ("c" "Copy resource name" kubel-copy-resource-name)
    ("$" "Show Process buffer" kubel-show-process-buffer)]])

;; mode map
(defvar kubel-talos-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") 'kubel-talos-get-resource-details)
    (define-key map (kbd "h") 'kubel-talos-help-popup)
    (define-key map (kbd "?") 'kubel-talos-help-popup)
    (define-key map (kbd "C") 'kubel-talos-set-context)
    (define-key map (kbd "n") 'kubel-talos-set-nodes)
    (define-key map (kbd "R") 'kubel-talos-set-resource)
    (define-key map (kbd "K") 'kubel-talos-set-config-file)
    (define-key map (kbd "a") 'kubel-talos-node-popup)
    (define-key map (kbd "l") 'kubel-talos-log-popup)
    (define-key map (kbd "S") 'kubel-talos-service-popup)
    (define-key map (kbd "c") 'kubel-copy-resource-name)
    ;; kubectl-only commands that don't apply to talos
    (dolist (key '("E" "F" "y" "s" "k" "r" "p" "e" "!" "j"))
      (define-key map (kbd key) 'undefined))
    map)
  "Keymap for `kubel-talos-mode'.")

(define-derived-mode kubel-talos-mode kubel-mode "Kubel-Talos"
  "Special mode for kubel Talos buffers."
  (setq kubel--buffer-prefix "kubel-talos")
  (setq kubel--kubernetes-context-p nil)
  (setq kubel--populate-function #'kubel-talos--populate-list))

;;;###autoload
(defun kubel-talos (&optional resource)
  "Invoke the kubel Talos buffer.
RESOURCE defaults to services."
  (interactive)
  (kubel--open-in-mode #'kubel-talos-mode (or resource "services") #'kubel-talos--init-context))

(provide 'kubel-talos)
;;; kubel-talos.el ends here
