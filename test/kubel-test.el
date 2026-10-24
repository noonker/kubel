;;; package --- Summary

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-macs)

(ert-deftest kubel--test-extract-value ()
  (let ((line "0123456789"))
    (should (equal "0" (kubel--extract-value line 0 1)))
    (should (equal "0123" (kubel--extract-value line 0 4)))
    (should (equal "34567" (kubel--extract-value line 3 8)))
    (should (equal "56789" (kubel--extract-value line 5 "end")))
    (should (equal "-" (kubel--extract-value "     " 0 5)))
    (should (equal "-" (kubel--extract-value "  " 0 "end")))))

;; extensions

(require 'kubel-argo)
(require 'kubel-talos)
(require 'kubel-helm)

(ert-deftest kubel--test-parse-argo-cron ()
  (let* ((body (concat "NAME                   AGE    LAST RUN   NEXT RUN   SCHEDULES     TIMEZONE   SUSPENDED\n"
                       "example-poller         169d   11m        3m         */5 * * * *              false\n"))
         (entrylist (kubel--parse-body body)))
    (should (equal '("NAME" "AGE" "LAST RUN" "NEXT RUN" "SCHEDULES" "TIMEZONE" "SUSPENDED")
                   (car entrylist)))
    (should (equal '("example-poller" "169d" "11m" "3m" "*/5 * * * *" "-" "false")
                   (cadr entrylist)))))

(ert-deftest kubel--test-talos-move-column-to-front ()
  (let* ((body (concat "NODE            NAMESPACE   ID                          IMAGE   PID     STATUS\n"
                       "192.0.2.10      k8s.io      demo/demo-pod                       63988   SANDBOX_READY\n"
                       "192.0.2.10      k8s.io      └─ demo/demo-pod:demo:9c8f          64225   CONTAINER_RUNNING\n"))
         (entrylist (kubel-talos--move-column-to-front (kubel--parse-body body) "ID")))
    (should (equal '("ID" "NODE" "NAMESPACE" "IMAGE" "PID" "STATUS") (car entrylist)))
    (should (equal "demo/demo-pod" (car (nth 1 entrylist))))
    (should (equal "demo/demo-pod:demo:9c8f" (car (nth 2 entrylist))))
    (should (equal "192.0.2.10" (nth 1 (nth 2 entrylist))))))

(ert-deftest kubel--test-talos-populate-services ()
  (with-temp-buffer
    (kubel-talos-mode)
    (setq kubel-context "my-cluster" kubel-namespace "" kubel-resource "services")
    (cl-letf (((symbol-function 'kubel--exec-sync)
               (lambda (cmd &rest _)
                 (should (equal "talosctl --context my-cluster services" cmd))
                 (concat "NODE            SERVICE   STATE     HEALTH   LAST CHANGE   LAST EVENT\n"
                         "192.0.2.10      apid      Running   OK       2m29s ago     Health check successful\n"))))
      (let ((entries (cadr (kubel-talos--populate-list))))
        (should (equal "apid" (car (car entries))))
        (should (equal "192.0.2.10" (aref (cadr (car entries)) 1)))))))

(ert-deftest kubel--test-argo-buffer-name-and-args ()
  (with-temp-buffer
    (kubel-argo-mode)
    (setq kubel-context "ctx" kubel-namespace "argo" kubel-resource "cron")
    (should (equal "*kubel-argo:ctx:argo:cron*" (kubel--buffer-name)))
    (should (equal '("cron" "get" "x") (kubel-argo--subcommand "get" "x")))
    (setq kubel-resource "workflows")
    (should (equal '("get" "x") (kubel-argo--subcommand "get" "x")))
    (cl-letf (((symbol-function 'kubel--exec-sync)
               (lambda (cmd &rest _)
                 (should (equal "argo --context ctx -n argo list" cmd))
                 "NAME   STATUS      AGE\nwf-1   Succeeded   9m\n")))
      (should (equal "wf-1" (caar (cadr (kubel-argo--populate-list))))))))

;; helm

(ert-deftest kubel--test-helm-populate-and-chart-name ()
  (with-temp-buffer
    (kubel-helm-mode)
    (setq kubel-context "ctx" kubel-namespace "" kubel-resource "releases")
    (cl-letf (((symbol-function 'kubel--exec-sync)
               (lambda (cmd &rest _)
                 (should (equal "helm --kube-context ctx list --all-namespaces -o json" cmd))
                 "[{\"name\":\"my-release\",\"namespace\":\"my-namespace\",\"revision\":\"1\",\"updated\":\"2026-01-02 03:04:05.123456789 +0000 UTC\",\"status\":\"deployed\",\"chart\":\"my-chart-v1.2.3\",\"app_version\":\"v1.2.3\"},{\"name\":\"other-release\",\"namespace\":\"other-namespace\",\"revision\":\"4\",\"updated\":\"2026-01-03 04:05:06.123456789 +0000 UTC\",\"status\":\"failed\",\"chart\":\"other-chart-84.5.0\",\"app_version\":\"\"}]")))
      (let ((entries (kubel-helm--populate-list)))
        (setq tabulated-list-format (car entries)
              tabulated-list-entries (cadr entries))
        (tabulated-list-init-header)
        (tabulated-list-print)
        (should (equal "my-release" (car (car tabulated-list-entries))))
        (should (equal "2026-01-02 03:04:05" (aref (cadr (car tabulated-list-entries)) 3)))
        (should (equal "-" (aref (cadr (cadr tabulated-list-entries)) 6)))
        (goto-char (point-min))
        (should (equal "my-chart" (kubel-helm--chart-name)))
        (should (equal "my-namespace" (kubel-helm--release-namespace)))
        (forward-line 1)
        (should (equal "other-chart" (kubel-helm--chart-name)))
        (should (equal "other-namespace" (kubel-helm--release-namespace)))))))

(ert-deftest kubel--test-helm-upgrade-args ()
  (should (equal '("--reuse-values") (kubel-helm--upgrade-args nil)))
  (should (equal '("--values=/tmp/v.yaml") (kubel-helm--upgrade-args '("--values=/tmp/v.yaml"))))
  (should (equal '("--reset-then-reuse-values") (kubel-helm--upgrade-args '("--reset-then-reuse-values")))))

;; (ert "kubel--test-.*")

(provide 'kubel-test)
;;; kubel-test.el ends here
