;;; kubel-argo.el --- Argo Workflows porcelain for kubel -*- lexical-binding: t; -*-

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
;; Keywords: kubernetes k8s tools processes argo
;; URL: https://github.com/abrochard/kubel
;; License: GNU General Public License >= 3
;; Package-Requires: ((kubel "1.0") (transient "0.1.0") (dash "2.12.0") (emacs "25.3"))

;;; Commentary:

;; Manage Argo Workflows from a kubel-style buffer, using the `argo' CLI.

;;; Usage:

;; M-x kubel-argo
;;
;; Lists the workflows in the current kubel context and namespace.  Use
;; `R' to switch between workflows, cron workflows, workflow templates
;; and cluster workflow templates.

;;; Shortcuts:

;; On the kubel-argo screen, place your cursor on a resource
;;
;; enter => argo get
;; C-u enter => argo get -o yaml
;; h => help popup
;; ? => help popup
;; g => refresh
;; a => actions popup (retry/resubmit/stop/terminate/suspend/resume/submit)
;; l => log popup
;; w => watch workflow
;; k => delete popup
;; C => set context
;; n => set namespace
;; R => set argo resource
;; f, M-n, M-p, m, u, M, U, c, $, b, q => as in kubel

;;; Code:

(require 'kubel)

(defcustom kubel-argo-program "argo"
  "Argo binary path."
  :type '(file :must-match t)
  :group 'kubel)

(defconst kubel-argo--resources
  '(("workflows" "list" nil nil)
    ("cron" "cron list" "cron" "cronwf")
    ("templates" "template list" "template" "workflowtemplate")
    ("cluster-templates" "cluster-template list" "cluster-template" "clusterworkflowtemplate"))
  "Argo resources as (NAME LIST-SUBCOMMAND SUBCOMMAND SUBMIT-KIND).
SUBCOMMAND is the argo subcommand used for get/delete, nil for workflows.
SUBMIT-KIND is used with `argo submit --from', nil if not submittable.")

(defun kubel-argo--resource-info ()
  "Return the `kubel-argo--resources' entry for the current resource."
  (or (assoc kubel-resource kubel-argo--resources)
      (car kubel-argo--resources)))

(defun kubel-argo--subcommand (&rest args)
  "Return the argo subcommand for the current resource, followed by ARGS."
  (let ((sub (nth 2 (kubel-argo--resource-info))))
    (if sub (cons sub args) args)))

(defun kubel-argo--workflow-view-p ()
  "Return non-nil if this is the workflows view."
  (equal kubel-resource "workflows"))

(defun kubel-argo--exec (process-name args &optional readonly callback)
  "Run argo asynchronously with ARGS in the current context and namespace.
PROCESS-NAME, READONLY and CALLBACK are as in `kubel--exec-program-async'."
  (kubel--exec-program-async process-name kubel-argo-program
                             (kubel--get-context-namespace) args readonly callback))

(defun kubel-argo--populate-list ()
  "Return the tabulated list format and entries for the current argo resource."
  (let* ((body (kubel--exec-sync
                (mapconcat #'identity
                           (append (list kubel-argo-program)
                                   (mapcar #'shell-quote-argument (kubel--get-context-namespace))
                                   (list (nth 1 (kubel-argo--resource-info))))
                           " ")))
         (entrylist (kubel--parse-body body)))
    (list (kubel--get-list-format entrylist) (kubel--get-list-entries entrylist))))

(defun kubel-argo--select-workflow ()
  "Return the workflows to act on.
The marked or current workflows in workflow view, otherwise prompt."
  (if (kubel-argo--workflow-view-p)
      (kubel--marked-or-current-items)
    (list (kubel--select-resource "workflows"))))

(defun kubel-argo-get (&optional yaml)
  "Show the argo resource under cursor.
With prefix argument YAML, show it as yaml."
  (interactive "P")
  (let ((name (kubel--get-resource-under-cursor)))
    (kubel-argo--exec (format "kubel - argo get - %s" name)
                      (append (kubel-argo--subcommand "get" name)
                              (when yaml '("-o" "yaml")))
                      t
                      (lambda () (goto-char (point-min))))))

(defun kubel-argo-logs (&optional args)
  "Show the logs of the workflow under cursor.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-argo-log-popup)))
  (dolist (wf (kubel-argo--select-workflow))
    (kubel-argo--exec (format "kubel - argo logs - %s" wf)
                      (append (list "logs" wf) args) t)))

(defun kubel-argo-watch ()
  "Watch the workflow under cursor until it completes."
  (interactive)
  (dolist (wf (kubel-argo--select-workflow))
    (kubel-argo--exec (format "kubel - argo watch - %s" wf) (list "watch" wf) t)))

(defun kubel-argo--workflow-action (action)
  "Run argo ACTION on the marked or current workflows, then refresh."
  (let ((wfs (kubel-argo--select-workflow))
        (list-buffer (current-buffer)))
    (kubel-argo--exec (format "kubel - argo %s - %s" action (string-join wfs ","))
                      (cons action wfs) t
                      (lambda ()
                        (when (buffer-live-p list-buffer)
                          (with-current-buffer list-buffer (kubel-refresh)))))))

(defun kubel-argo-retry ()
  "Retry the marked or current workflows."
  (interactive)
  (kubel-argo--workflow-action "retry"))

(defun kubel-argo-resubmit ()
  "Resubmit the marked or current workflows."
  (interactive)
  (kubel-argo--workflow-action "resubmit"))

(defun kubel-argo-stop ()
  "Stop the marked or current workflows, running exit handlers."
  (interactive)
  (kubel-argo--workflow-action "stop"))

(defun kubel-argo-terminate ()
  "Terminate the marked or current workflows immediately."
  (interactive)
  (when (y-or-n-p "Terminate workflow(s) immediately? ")
    (kubel-argo--workflow-action "terminate")))

(defun kubel-argo-suspend ()
  "Suspend the marked or current workflows or cron workflows."
  (interactive)
  (if (equal kubel-resource "cron")
      (kubel-argo--cron-action "suspend")
    (kubel-argo--workflow-action "suspend")))

(defun kubel-argo-resume ()
  "Resume the marked or current workflows or cron workflows."
  (interactive)
  (if (equal kubel-resource "cron")
      (kubel-argo--cron-action "resume")
    (kubel-argo--workflow-action "resume")))

(defun kubel-argo--cron-action (action)
  "Run argo cron ACTION on the marked or current cron workflows, then refresh."
  (let ((crons (kubel--marked-or-current-items))
        (list-buffer (current-buffer)))
    (kubel-argo--exec (format "kubel - argo cron %s - %s" action (string-join crons ","))
                      (append (list "cron" action) crons) t
                      (lambda ()
                        (when (buffer-live-p list-buffer)
                          (with-current-buffer list-buffer (kubel-refresh)))))))

(defun kubel-argo-submit (&optional args)
  "Submit a workflow from the cron workflow or template under cursor.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-argo-submit-popup)))
  (let ((kind (nth 3 (kubel-argo--resource-info))))
    (unless kind
      (user-error "Switch to cron workflows or templates (R) to submit"))
    (let ((name (kubel--get-resource-under-cursor)))
      (kubel-argo--exec (format "kubel - argo submit - %s/%s" kind name)
                        (append (list "submit" "--from" (format "%s/%s" kind name)) args)
                        t))))

(defun kubel-argo-delete (&optional args)
  "Delete the marked or current argo resources.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-argo-delete-popup)))
  (let ((names (kubel--marked-or-current-items))
        (list-buffer (current-buffer)))
    (when (y-or-n-p (format "Delete %s? " (string-join names ", ")))
      (kubel-argo--exec (format "kubel - argo delete - %s" (string-join names ","))
                        (append (kubel-argo--subcommand "delete") names args)
                        nil
                        (lambda ()
                          (when (buffer-live-p list-buffer)
                            (with-current-buffer list-buffer (kubel-refresh))))))))

(defun kubel-argo-set-resource ()
  "Set the argo resource to display."
  (interactive)
  (let ((parent-buffer (current-buffer))
        (resource (completing-read "Select argo resource: "
                                   (mapcar #'car kubel-argo--resources) nil t)))
    (with-current-buffer (clone-buffer)
      (setq kubel--parent-buffer parent-buffer)
      (setq kubel-resource resource)
      (setq kubel--selected-items '())
      (switch-to-buffer (current-buffer))
      (kubel-refresh))))

;; popups

(transient-define-prefix kubel-argo-log-popup ()
  "Kubel Argo Log Menu"
  ["Arguments"
   ("-f" "Follow" "--follow")
   ("-p" "Previous" "--previous")
   ("-t" "Timestamps" "--timestamps")
   ("-n" "Tail" "--tail=")
   ("-c" "Container" "--container=")
   ("-g" "Grep" "--grep=")
   ("-s" "Since" "--since=")]
  ["Actions"
   ("l" "Workflow logs" kubel-argo-logs)])

(transient-define-prefix kubel-argo-submit-popup ()
  "Kubel Argo Submit Menu"
  ["Arguments"
   ("-l" "Log until completion" "--log")
   ("-w" "Watch until completion" "--watch")
   ("-p" "Parameter" "--parameter=")
   ("-g" "Generate name" "--generate-name=")]
  ["Actions"
   ("s" "Submit from resource" kubel-argo-submit)])

(transient-define-prefix kubel-argo-delete-popup ()
  "Kubel Argo Delete Menu"
  ["Arguments"
   ("-c" "Completed only (workflows)" "--completed")
   ("-o" "Older than (workflows)" "--older=")]
  ["Actions"
   ("k" "Delete resource(s)" kubel-argo-delete)])

(transient-define-prefix kubel-argo-action-popup ()
  "Kubel Argo Action Menu"
  [["Workflows"
    ("r" "Retry" kubel-argo-retry)
    ("R" "Resubmit" kubel-argo-resubmit)
    ("s" "Stop" kubel-argo-stop)
    ("t" "Terminate" kubel-argo-terminate)]
   ["Workflows / Cron"
    ("z" "Suspend" kubel-argo-suspend)
    ("Z" "Resume" kubel-argo-resume)]
   ["Cron / Templates"
    ("S" "Submit..." kubel-argo-submit-popup)]])

(transient-define-prefix kubel-argo-help-popup ()
  "Kubel Argo Menu"
  [["Actions"
    ("RET" "Get (C-u for yaml)" kubel-argo-get)
    ("a" "Actions..." kubel-argo-action-popup)
    ("l" "Logs" kubel-argo-log-popup)
    ("w" "Watch" kubel-argo-watch)
    ("k" "Delete" kubel-argo-delete-popup)
    ("g" "Refresh" kubel-refresh)
    ("b" "Buffers" kubel-switch-to-buffer)]
   ["Settings"
    ("C" "Set context" kubel-set-context)
    ("n" "Set namespace" kubel-set-namespace)
    ("R" "Set argo resource" kubel-argo-set-resource)]
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
    ("c" "Copy to clipboad..." kubel-copy-popup)
    ("$" "Show Process buffer" kubel-show-process-buffer)]])

;; mode map
(defvar kubel-argo-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") 'kubel-argo-get)
    (define-key map (kbd "h") 'kubel-argo-help-popup)
    (define-key map (kbd "?") 'kubel-argo-help-popup)
    (define-key map (kbd "R") 'kubel-argo-set-resource)
    (define-key map (kbd "a") 'kubel-argo-action-popup)
    (define-key map (kbd "l") 'kubel-argo-log-popup)
    (define-key map (kbd "w") 'kubel-argo-watch)
    (define-key map (kbd "k") 'kubel-argo-delete-popup)
    ;; kubectl-only commands that don't apply to argo resources
    (dolist (key '("E" "F" "y" "s" "r" "p" "e" "!" "j" "S"))
      (define-key map (kbd key) 'undefined))
    map)
  "Keymap for `kubel-argo-mode'.")

(define-derived-mode kubel-argo-mode kubel-mode "Kubel-Argo"
  "Special mode for kubel argo buffers."
  (setq kubel--buffer-prefix "kubel-argo")
  (setq kubel--populate-function #'kubel-argo--populate-list))

;;;###autoload
(defun kubel-argo (&optional resource)
  "Invoke the kubel argo buffer.
RESOURCE is one of `kubel-argo--resources', default to workflows."
  (interactive)
  (kubel--open-in-mode #'kubel-argo-mode (or resource "workflows")))

(provide 'kubel-argo)
;;; kubel-argo.el ends here
