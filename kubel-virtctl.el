;;; kubel-virtctl.el --- KubeVirt porcelain for kubel -*- lexical-binding: t; -*-

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
;; Keywords: kubernetes k8s tools processes kubevirt
;; URL: https://github.com/abrochard/kubel
;; License: GNU General Public License >= 3
;; Package-Requires: ((kubel "1.0") (transient "0.1.0") (dash "2.12.0") (emacs "25.3"))

;;; Commentary:

;; Manage KubeVirt virtual machines from a kubel-style buffer, using
;; kubectl to list resources and the `virtctl' CLI to act on them.

;;; Usage:

;; M-x kubel-virtctl
;;
;; Lists the virtual machines in the current kubel context and namespace.
;; Use `R' to switch to another KubeVirt resource (VMIs, data volumes, ...).

;;; Shortcuts:

;; On the kubel-virtctl screen, place your cursor on a VM
;;
;; a => lifecycle popup (start/stop/restart/pause/unpause/migrate/...)
;; e => console popup (serial console/ssh/vnc)
;; i => guest info popup (os info/filesystems/users)
;; p => port forward VM
;; R => set KubeVirt resource
;; everything else => as in kubel

;;; Code:

(require 'kubel)

(defcustom kubel-virtctl-program "virtctl"
  "Virtctl binary path."
  :type '(file :must-match t)
  :group 'kubel)

(defvar kubel-virtctl-ssh-user-history '()
  "List of previously used ssh users.")

(defun kubel-virtctl--vmi-view-p ()
  "Return non-nil if this is the virtual machine instances view."
  (string-prefix-p "virtualmachineinstances" kubel-resource))

(defun kubel-virtctl--vm-view-p ()
  "Return non-nil if this is the virtual machines or instances view."
  (or (kubel-virtctl--vmi-view-p)
      (member kubel-resource '("vm" "vms" "virtualmachines" "virtualmachines.kubevirt.io"))))

(defun kubel-virtctl--select-vms ()
  "Return the VMs to act on.
The marked or current VMs in VM view, otherwise prompt."
  (if (kubel-virtctl--vm-view-p)
      (kubel--marked-or-current-items)
    (list (kubel--select-resource "virtualmachines"))))

(defun kubel-virtctl--select-vm ()
  "Return a single VM to act on, the current one in VM view or prompt."
  (if (kubel-virtctl--vm-view-p)
      (kubel--get-resource-under-cursor)
    (kubel--select-resource "virtualmachines")))

(defun kubel-virtctl--type-name (vm)
  "Return the vm/VM or vmi/VM target used by ssh and port-forward."
  (format "%s/%s" (if (kubel-virtctl--vmi-view-p) "vmi" "vm") vm))

(defun kubel-virtctl--args (args allowed)
  "Return the transient ARGS that are in ALLOWED, split into separate arguments."
  (mapcan #'split-string (seq-intersection args allowed)))

(defun kubel-virtctl--exec (process-name args &optional readonly callback)
  "Run virtctl asynchronously with ARGS in the current context and namespace.
PROCESS-NAME, READONLY and CALLBACK are as in `kubel--exec-program-async'."
  (kubel--exec-program-async process-name kubel-virtctl-program
                             (kubel--get-context-namespace) args readonly callback))

(defun kubel-virtctl--lifecycle (action &optional args confirm)
  "Run virtctl ACTION with ARGS on the selected VMs, then refresh.
If CONFIRM is non-nil, ask before running."
  (let ((vms (kubel-virtctl--select-vms))
        (list-buffer (current-buffer)))
    (when (or (not confirm)
              (y-or-n-p (format "%s %s? " (capitalize action) (string-join vms ", "))))
      (dolist (vm vms)
        (kubel-virtctl--exec (format "kubel - virtctl %s - %s" action vm)
                             (append (list action vm) args) t
                             (lambda ()
                               (when (buffer-live-p list-buffer)
                                 (with-current-buffer list-buffer (kubel-refresh)))))))))

(defun kubel-virtctl-start (&optional args)
  "Start the marked or current VMs.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-virtctl-lifecycle-popup)))
  (kubel-virtctl--lifecycle "start" (kubel-virtctl--args args '("--paused" "--dry-run"))))

(defun kubel-virtctl-stop (&optional args)
  "Stop the marked or current VMs.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-virtctl-lifecycle-popup)))
  (kubel-virtctl--lifecycle "stop" (kubel-virtctl--args args '("--force --grace-period=0" "--dry-run"))
                            t))

(defun kubel-virtctl-restart (&optional args)
  "Restart the marked or current VMs.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-virtctl-lifecycle-popup)))
  (kubel-virtctl--lifecycle "restart" (kubel-virtctl--args args '("--force --grace-period=0" "--dry-run"))
                            t))

(defun kubel-virtctl-soft-reboot ()
  "Soft reboot the marked or current VMIs through the guest agent."
  (interactive)
  (kubel-virtctl--lifecycle "soft-reboot" nil t))

(defun kubel-virtctl-pause ()
  "Pause the marked or current VMs."
  (interactive)
  (let ((vms (kubel-virtctl--select-vms)))
    (dolist (vm vms)
      (kubel-virtctl--exec (format "kubel - virtctl pause - %s" vm)
                           (list "pause" (if (kubel-virtctl--vmi-view-p) "vmi" "vm") vm) t))))

(defun kubel-virtctl-unpause ()
  "Unpause the marked or current VMs."
  (interactive)
  (let ((vms (kubel-virtctl--select-vms)))
    (dolist (vm vms)
      (kubel-virtctl--exec (format "kubel - virtctl unpause - %s" vm)
                           (list "unpause" (if (kubel-virtctl--vmi-view-p) "vmi" "vm") vm) t))))

(defun kubel-virtctl-migrate (&optional args)
  "Live migrate the marked or current VMs.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-virtctl-lifecycle-popup)))
  (kubel-virtctl--lifecycle "migrate" (kubel-virtctl--args args '("--dry-run")) t))

(defun kubel-virtctl-migrate-cancel ()
  "Cancel the migration of the marked or current VMs."
  (interactive)
  (kubel-virtctl--lifecycle "migrate-cancel"))

(defun kubel-virtctl--term-name (type vm)
  "Return the term buffer name for a TYPE session on VM."
  (format "kubel-virtctl:%s:%s:%s:%s" kubel-context kubel-namespace type vm))

(defun kubel-virtctl-console ()
  "Connect to the serial console of the VM under cursor."
  (interactive)
  (let ((vm (kubel-virtctl--select-vm)))
    (kubel--run-in-term (kubel-virtctl--term-name "console" vm) kubel-virtctl-program
                        (append (kubel--get-context-namespace) (list "console" vm)))))

(defun kubel-virtctl-ssh (user)
  "Open a ssh session as USER to the VM under cursor."
  (interactive (list (read-string "User: " (car kubel-virtctl-ssh-user-history)
                                  'kubel-virtctl-ssh-user-history)))
  (let ((vm (kubel-virtctl--select-vm)))
    (kubel--run-in-term (kubel-virtctl--term-name "ssh" vm) kubel-virtctl-program
                        (append (kubel--get-context-namespace)
                                (list "ssh" (format "%s@%s" user (kubel-virtctl--type-name vm)))))))

(defun kubel-virtctl-vnc (&optional args)
  "Open a vnc connection to the VM under cursor.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-virtctl-console-popup)))
  (let ((vm (kubel-virtctl--select-vm)))
    (kubel-virtctl--exec (format "kubel - virtctl vnc - %s" vm)
                         (append (list "vnc" vm) (kubel-virtctl--args args '("--proxy-only"))) t)))

(defun kubel-virtctl-port-forward (p)
  "Port forward the VM under cursor to your local machine.

P can be a single number or a localhost:VM port pair."
  (interactive "sPort: ")
  (let* ((port (if (string-match-p ":" p) p (format "%s:%s" p p)))
         (target (kubel-virtctl--type-name (kubel-virtctl--select-vm))))
    (kubel-virtctl--exec (format "kubel - virtctl port-forward - %s:%s" target port)
                         (list "port-forward" target port))))

(defun kubel-virtctl--guest-info (command)
  "Show the output of the guest agent COMMAND for the VM under cursor."
  (let ((vm (kubel-virtctl--select-vm)))
    (kubel-virtctl--exec (format "kubel - virtctl %s - %s" command vm)
                         (list command vm) t
                         (lambda ()
                           (goto-char (point-min))
                           (when (fboundp 'js-json-mode) (js-json-mode))))))

(defun kubel-virtctl-guestosinfo ()
  "Show the guest OS info of the VM under cursor."
  (interactive)
  (kubel-virtctl--guest-info "guestosinfo"))

(defun kubel-virtctl-fslist ()
  "Show the guest filesystems of the VM under cursor."
  (interactive)
  (kubel-virtctl--guest-info "fslist"))

(defun kubel-virtctl-userlist ()
  "Show the users logged into the VM under cursor."
  (interactive)
  (kubel-virtctl--guest-info "userlist"))

(defun kubel-virtctl-objectgraph ()
  "Show the dependency graph of the VM under cursor."
  (interactive)
  (kubel-virtctl--guest-info "objectgraph"))

(defun kubel-virtctl-set-resource (&optional refresh)
  "Set the KubeVirt resource to display.
If called with a prefix argument REFRESH, refreshes the cached resource list."
  (interactive "P")
  (when refresh (kubel--invalidate-context-caches))
  (let ((parent-buffer (current-buffer))
        (resource (completing-read
                   "Select KubeVirt resource: "
                   (-filter (lambda (r) (string-match-p "kubevirt\\.io$" r))
                            (kubel--kubernetes-resources-list)))))
    (with-current-buffer (clone-buffer)
      (setq kubel--parent-buffer parent-buffer)
      (setq kubel-resource resource)
      (setq kubel--selected-items '())
      (switch-to-buffer (current-buffer))
      (kubel-refresh))))

;; popups

(transient-define-prefix kubel-virtctl-lifecycle-popup ()
  "Kubel Virtctl Lifecycle Menu"
  ["Arguments"
   ("-p" "Start paused" "--paused")
   ("-f" "Force (stop/restart)" "--force --grace-period=0")
   ("-d" "Dry run" "--dry-run")]
  [["Power"
    ("s" "Start" kubel-virtctl-start)
    ("S" "Stop" kubel-virtctl-stop)
    ("r" "Restart" kubel-virtctl-restart)
    ("b" "Soft reboot" kubel-virtctl-soft-reboot)]
   ["Pause"
    ("z" "Pause" kubel-virtctl-pause)
    ("Z" "Unpause" kubel-virtctl-unpause)]
   ["Migration"
    ("m" "Migrate" kubel-virtctl-migrate)
    ("M" "Cancel migration" kubel-virtctl-migrate-cancel)]])

(transient-define-prefix kubel-virtctl-console-popup ()
  "Kubel Virtctl Console Menu"
  ["Arguments"
   ("-p" "VNC proxy only" "--proxy-only")]
  ["Actions"
   ("c" "Serial console" kubel-virtctl-console)
   ("s" "SSH" kubel-virtctl-ssh)
   ("v" "VNC" kubel-virtctl-vnc)])

(transient-define-prefix kubel-virtctl-info-popup ()
  "Kubel Virtctl Guest Info Menu"
  ["Actions"
   ("o" "Guest OS info" kubel-virtctl-guestosinfo)
   ("f" "Filesystems" kubel-virtctl-fslist)
   ("u" "Users" kubel-virtctl-userlist)
   ("g" "Object graph" kubel-virtctl-objectgraph)])

(transient-define-prefix kubel-virtctl-help-popup ()
  "Kubel Virtctl Menu"
  [["Actions"
    ("RET" "Resource details" kubel-describe-popup)
    ("E" "Quick edit" kubel-quick-edit)
    ("g" "Refresh" kubel-refresh)
    ("b" "Buffers" kubel-switch-to-buffer)
    ("k" "Delete" kubel-delete-popup)]
   ["Virtual machines"
    ("a" "Lifecycle..." kubel-virtctl-lifecycle-popup)
    ("e" "Console..." kubel-virtctl-console-popup)
    ("i" "Guest info..." kubel-virtctl-info-popup)
    ("p" "Port forward" kubel-virtctl-port-forward)
    ("l" "Logs" kubel-log-popup)]
   ["Settings"
    ("C" "Set context" kubel-set-context)
    ("n" "Set namespace" kubel-set-namespace)
    ("R" "Set KubeVirt resource" kubel-virtctl-set-resource)
    ("F" "Set output format" kubel-set-output-format)]
   ["Filter"
    ("f" "Filter" kubel-set-filter)
    ("M-n" "Next highlight" kubel-jump-to-next-highlight)
    ("M-p" "Previous highlight" kubel-jump-to-previous-highlight)
    ("s" "Set label selector" kubel-set-label-selector)]
   ["Marking"
    ("m" "Mark item" kubel-mark-item)
    ("u" "Unmark item" kubel-unmark-item)
    ("M" "Mark all items" kubel-mark-all)
    ("U" "Unmark all items" kubel-unmark-all)]
   ["Utilities"
    ("c" "Copy to clipboad..." kubel-copy-popup)
    ("$" "Show Process buffer" kubel-show-process-buffer)]])

;; mode map
(defvar kubel-virtctl-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "h") 'kubel-virtctl-help-popup)
    (define-key map (kbd "?") 'kubel-virtctl-help-popup)
    (define-key map (kbd "R") 'kubel-virtctl-set-resource)
    (define-key map (kbd "a") 'kubel-virtctl-lifecycle-popup)
    (define-key map (kbd "e") 'kubel-virtctl-console-popup)
    (define-key map (kbd "i") 'kubel-virtctl-info-popup)
    (define-key map (kbd "p") 'kubel-virtctl-port-forward)
    (dolist (key '("y" "r" "!" "j" "S"))
      (define-key map (kbd key) 'undefined))
    map)
  "Keymap for `kubel-virtctl-mode'.")

(define-derived-mode kubel-virtctl-mode kubel-mode "Kubel-Virtctl"
  "Special mode for kubel KubeVirt buffers."
  (setq kubel--buffer-prefix "kubel-virtctl"))

;;;###autoload
(defun kubel-virtctl (&optional resource)
  "Invoke the kubel KubeVirt buffer.
RESOURCE defaults to virtualmachines."
  (interactive)
  (kubel--open-in-mode #'kubel-virtctl-mode (or resource "virtualmachines")))

(provide 'kubel-virtctl)
;;; kubel-virtctl.el ends here
