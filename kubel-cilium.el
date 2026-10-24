;;; kubel-cilium.el --- Cilium porcelain for kubel -*- lexical-binding: t; -*-

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
;; Keywords: kubernetes k8s tools processes cilium
;; URL: https://github.com/abrochard/kubel
;; License: GNU General Public License >= 3
;; Package-Requires: ((kubel "1.0") (transient "0.1.0") (dash "2.12.0") (emacs "25.3"))

;;; Commentary:

;; Inspect Cilium from a kubel-style buffer.  Cilium resources (endpoints,
;; network policies, nodes, identities...) are listed with kubectl, the
;; `cilium' CLI is used for status and diagnostics, and the `hubble' CLI,
;; if installed, is used to observe flows.

;;; Usage:

;; M-x kubel-cilium
;;
;; Lists the Cilium endpoints in the current kubel context and namespace.
;; Use `R' to switch to another Cilium resource.

;;; Shortcuts:

;; On the kubel-cilium screen, place your cursor on a resource
;;
;; a => cilium popup (status/connectivity test/features/config/bgp/...)
;; o => hubble observe popup
;; R => set Cilium resource
;; everything else => as in kubel

;;; Code:

(require 'kubel)

(defcustom kubel-cilium-program "cilium"
  "Cilium CLI binary path."
  :type '(file :must-match t)
  :group 'kubel)

(defcustom kubel-cilium-hubble-program "hubble"
  "Hubble CLI binary path."
  :type '(file :must-match t)
  :group 'kubel)

(defcustom kubel-cilium-namespace nil
  "Namespace Cilium is installed in, nil for the cilium CLI default."
  :type '(choice (const :tag "Default" nil) string)
  :group 'kubel)

(defun kubel-cilium--global-args ()
  "Return the context and namespace arguments for the cilium CLI.
The namespace is where Cilium runs, not the namespace of the buffer."
  (append
   (unless (member kubel-context '(nil ""))
     (list "--context" kubel-context))
   (when kubel-cilium-namespace
     (list "--namespace" kubel-cilium-namespace))))

(defun kubel-cilium--exec (process-name args &optional callback)
  "Run cilium asynchronously with ARGS in the current context.
PROCESS-NAME and CALLBACK are as in `kubel--exec-program-async'.
ANSI colors of the output are turned into faces."
  (kubel--exec-program-async process-name kubel-cilium-program
                             (kubel-cilium--global-args) args t
                             (or callback (lambda () (goto-char (point-min))))
                             #'kubel--ansi-color-filter))

(defun kubel-cilium-status (&optional args)
  "Show the Cilium status.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-cilium-popup)))
  (kubel-cilium--exec "kubel - cilium status"
                      (append '("status") (seq-intersection args '("--wait" "--verbose")))))

(defun kubel-cilium-connectivity-test (&optional args)
  "Run the Cilium connectivity test.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-cilium-popup)))
  (when (y-or-n-p "Deploy the connectivity test workloads to the cluster? ")
    (kubel-cilium--exec "kubel - cilium connectivity test"
                        (append '("connectivity" "test")
                                (seq-filter (lambda (a) (string-prefix-p "--test=" a)) args)))))

(defun kubel-cilium-features ()
  "Show the features enabled in the Cilium agents."
  (interactive)
  (kubel-cilium--exec "kubel - cilium features" '("features" "status")))

(defun kubel-cilium-config ()
  "Show the Cilium configuration."
  (interactive)
  (kubel-cilium--exec "kubel - cilium config" '("config" "view")))

(defun kubel-cilium-bgp-peers ()
  "Show the BGP peering state."
  (interactive)
  (kubel-cilium--exec "kubel - cilium bgp peers" '("bgp" "peers")))

(defun kubel-cilium-bgp-routes ()
  "Show the BGP routes."
  (interactive)
  (kubel-cilium--exec "kubel - cilium bgp routes" '("bgp" "routes")))

(defun kubel-cilium-clustermesh-status ()
  "Show the ClusterMesh status."
  (interactive)
  (kubel-cilium--exec "kubel - cilium clustermesh status" '("clustermesh" "status")))

(defun kubel-cilium-encryption-status ()
  "Show the encryption status."
  (interactive)
  (kubel-cilium--exec "kubel - cilium encryption status" '("encryption" "status")))

(defun kubel-cilium-version ()
  "Show the Cilium CLI and running versions."
  (interactive)
  (kubel-cilium--exec "kubel - cilium version" '("version")))

(defun kubel-cilium-sysdump (directory)
  "Collect a Cilium sysdump into DIRECTORY."
  (interactive "DSave sysdump in: ")
  (let ((default-directory (file-name-as-directory (expand-file-name directory))))
    (kubel-cilium--exec "kubel - cilium sysdump" '("sysdump"))))

(defun kubel-cilium-hubble-port-forward ()
  "Forward the Hubble relay port to the local machine."
  (interactive)
  (kubel-cilium--exec "kubel - cilium hubble port-forward" '("hubble" "port-forward")))

(defun kubel-cilium-hubble-ui ()
  "Open the Hubble UI."
  (interactive)
  (kubel-cilium--exec "kubel - cilium hubble ui" '("hubble" "ui")))

(defun kubel-cilium--endpoint-view-p ()
  "Return non-nil if this is a Cilium endpoint view, whose names are pods."
  (string-prefix-p "ciliumendpoints" kubel-resource))

(defun kubel-cilium--observe (target args)
  "Run hubble observe for TARGET with ARGS.
TARGET is a list of hubble filter arguments."
  (unless (executable-find kubel-cilium-hubble-program)
    (user-error "Cannot find `%s', see `kubel-cilium-hubble-program'"
                kubel-cilium-hubble-program))
  (kubel--exec-program-async (format "kubel - hubble observe - %s" (string-join target " "))
                             kubel-cilium-hubble-program
                             (kubel-cilium--hubble-global-args args)
                             (append '("observe") target args)
                             t nil #'kubel--ansi-color-filter))

(defun kubel-cilium--hubble-global-args (args)
  "Return the hubble arguments to reach the relay of the current context.
When ARGS contain --port-forward, hubble forwards the relay port itself,
on a random local port so it doesn't clash with a running port-forward.
Otherwise it uses its configured server, see `cilium hubble port-forward'."
  (when (member "--port-forward" args)
    (append
     (list "--port-forward-port=0")
     (unless (member kubel-context '(nil ""))
       (list "--kube-context" kubel-context))
     (when kubel-cilium-namespace
       (list "--kube-namespace" kubel-cilium-namespace)))))

(defun kubel-cilium-observe-pod (&optional args)
  "Observe the flows of the pod under cursor.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-cilium-observe-popup)))
  (let ((pod (if (or (kubel--is-pod-view) (kubel-cilium--endpoint-view-p))
                 (kubel--get-resource-under-cursor)
               (kubel--select-resource "Pods"))))
    (kubel-cilium--observe (list "--pod" (format "%s/%s" kubel-namespace pod)) args)))

(defun kubel-cilium-observe-namespace (&optional args)
  "Observe the flows of the current namespace.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-cilium-observe-popup)))
  (kubel-cilium--observe (list "--namespace" kubel-namespace) args))

(defun kubel-cilium-observe-all (&optional args)
  "Observe the flows of the whole cluster.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-cilium-observe-popup)))
  (kubel-cilium--observe nil args))

(defun kubel-cilium-set-resource (&optional refresh)
  "Set the Cilium resource to display.
If called with a prefix argument REFRESH, refreshes the cached resource list."
  (interactive "P")
  (when refresh (kubel--invalidate-context-caches))
  (let ((parent-buffer (current-buffer))
        (resource (completing-read
                   "Select Cilium resource: "
                   (-filter (lambda (r) (string-match-p "cilium\\.io$" r))
                            (kubel--kubernetes-resources-list)))))
    (with-current-buffer (clone-buffer)
      (setq kubel--parent-buffer parent-buffer)
      (setq kubel-resource resource)
      (setq kubel--selected-items '())
      (switch-to-buffer (current-buffer))
      (kubel-refresh))))

;; popups

(transient-define-prefix kubel-cilium-popup ()
  "Kubel Cilium Menu"
  ["Arguments"
   ("-w" "Wait for status OK" "--wait")
   ("-v" "Verbose status" "--verbose")
   ("-t" "Connectivity tests to run" "--test=")]
  [["Status"
    ("s" "Status" kubel-cilium-status)
    ("f" "Features" kubel-cilium-features)
    ("c" "Config" kubel-cilium-config)
    ("v" "Version" kubel-cilium-version)]
   ["Networking"
    ("b" "BGP peers" kubel-cilium-bgp-peers)
    ("B" "BGP routes" kubel-cilium-bgp-routes)
    ("m" "ClusterMesh status" kubel-cilium-clustermesh-status)
    ("e" "Encryption status" kubel-cilium-encryption-status)]
   ["Troubleshooting"
    ("t" "Connectivity test" kubel-cilium-connectivity-test)
    ("d" "Sysdump" kubel-cilium-sysdump)
    ("p" "Hubble port-forward" kubel-cilium-hubble-port-forward)
    ("u" "Hubble UI" kubel-cilium-hubble-ui)]])

(transient-define-prefix kubel-cilium-observe-popup ()
  "Kubel Hubble Observe Menu"
  :value '("--port-forward")
  ["Arguments"
   ("-f" "Follow" "--follow")
   ("-P" "Port forward to relay" "--port-forward")
   ("-l" "Last N flows" "--last=")
   ("-v" "Verdict" "--verdict="
    :choices ("FORWARDED" "DROPPED" "ERROR" "AUDIT" "REDIRECTED" "TRACED" "TRANSLATED"))
   ("-p" "Protocol" "--protocol=")
   ("-o" "Output" "--output=" :choices ("compact" "dict" "json" "jsonpb" "table"))]
  ["Actions"
   ("o" "Pod" kubel-cilium-observe-pod)
   ("n" "Namespace" kubel-cilium-observe-namespace)
   ("a" "All" kubel-cilium-observe-all)])

(transient-define-prefix kubel-cilium-help-popup ()
  "Kubel Cilium Menu"
  [["Actions"
    ("RET" "Resource details" kubel-describe-popup)
    ("E" "Quick edit" kubel-quick-edit)
    ("g" "Refresh" kubel-refresh)
    ("b" "Buffers" kubel-switch-to-buffer)
    ("k" "Delete" kubel-delete-popup)]
   ["Cilium"
    ("a" "Cilium..." kubel-cilium-popup)
    ("o" "Observe flows..." kubel-cilium-observe-popup)
    ("l" "Logs" kubel-log-popup)]
   ["Settings"
    ("C" "Set context" kubel-set-context)
    ("n" "Set namespace" kubel-set-namespace)
    ("R" "Set Cilium resource" kubel-cilium-set-resource)
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
(defvar kubel-cilium-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "h") 'kubel-cilium-help-popup)
    (define-key map (kbd "?") 'kubel-cilium-help-popup)
    (define-key map (kbd "R") 'kubel-cilium-set-resource)
    (define-key map (kbd "a") 'kubel-cilium-popup)
    (define-key map (kbd "o") 'kubel-cilium-observe-popup)
    (dolist (key '("y" "r" "p" "e" "!" "j" "S"))
      (define-key map (kbd key) 'undefined))
    map)
  "Keymap for `kubel-cilium-mode'.")

(define-derived-mode kubel-cilium-mode kubel-mode "Kubel-Cilium"
  "Special mode for kubel Cilium buffers."
  (setq kubel--buffer-prefix "kubel-cilium"))

;;;###autoload
(defun kubel-cilium (&optional resource)
  "Invoke the kubel Cilium buffer.
RESOURCE defaults to ciliumendpoints."
  (interactive)
  (kubel--open-in-mode #'kubel-cilium-mode (or resource "ciliumendpoints.cilium.io")))

(provide 'kubel-cilium)
;;; kubel-cilium.el ends here
