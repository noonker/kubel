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

;; calico

(require 'kubel-calico)
(require 'kubel-sops)
(require 'kubel-kustomize)

(ert-deftest kubel--test-calico-normalize-table ()
  ;; a header ending with spaces would be a column, an empty line a row
  (let ((entrylist (kubel--parse-body
                    (kubel-calico--normalize-table
                     "NAME   ASN   IPV4   IPV6   \nnode-a                    \nnode-b 64512\n\n"))))
    (should (equal '("NAME" "ASN" "IPV4" "IPV6") (car entrylist)))
    (should (= 3 (length entrylist)))
    (should (equal "node-a" (car (nth 1 entrylist))))))

(ert-deftest kubel--test-calico-populate ()
  (with-temp-buffer
    (kubel-calico-mode)
    (setq kubel-context "ctx" kubel-namespace "kube-system" kubel-resource "workloadendpoints")
    (cl-letf (((symbol-function 'kubel--exec-sync)
               (lambda (cmd &rest _)
                 (should (equal "calicoctl --context ctx get workloadendpoints --namespace kube-system -o wide" cmd))
                 (concat "NAMESPACE     NAME      WORKLOAD   NODE     \n"
                         "kube-system   wep-one   pod-one    node-a   \n\n"))))
      (let ((result (kubel-calico--populate-list)))
        (should (equal "wep-one" (caar (cadr result))))
        (should (equal "kube-system" (aref (cadr (car (cadr result))) 1)))))))

(ert-deftest kubel--test-calico-list-command-scope ()
  (with-temp-buffer
    (kubel-calico-mode)
    (setq kubel-context "ctx" kubel-namespace "default" kubel-resource "nodes")
    ;; calicoctl fails with -n on a cluster scoped resource
    (should (equal "calicoctl --context ctx get nodes -o wide" (kubel-calico--list-command)))
    (setq kubel-resource "networkpolicies" kubel-namespace "")
    (should (equal "calicoctl --context ctx get networkpolicies --all-namespaces -o wide"
                   (kubel-calico--list-command)))
    (setq kubel-resource "profiles")
    (should (equal "calicoctl --context ctx get profiles" (kubel-calico--list-command)))))

(ert-deftest kubel--test-calico-ambiguous-name ()
  (with-temp-buffer
    (kubel-calico-mode)
    (setq kubel-resource "networkpolicies" kubel-namespace ""
          tabulated-list-format [("NAME" 5 t) ("NAMESPACE" 5 t)]
          tabulated-list-entries '(("dup" ["dup" "a"]) ("dup" ["dup" "b"]) ("one" ["one" "c"]))
          kubel--selected-items '("dup" "one"))
    (should (equal "c" (kubel-calico--item-namespace "one")))
    (should-error (kubel-calico--item-namespace "dup") :type 'user-error)))

;; sops

(ert-deftest kubel--test-sops-file-listing ()
  (let* ((dir (file-name-as-directory (make-temp-file "kubel-test" t)))
         (default-directory dir))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" dir))
          (make-directory (expand-file-name "sub" dir))
          (dolist (file '(".git/config.yaml" ".sops.yaml" "notes.txt" "plain.yaml" "sub/enc.yaml"))
            (write-region (if (equal file "sub/enc.yaml") "a: ENC[x]\nsops:\n  version: 3\n" "a: 1\n")
                          nil (expand-file-name file dir)))
          (with-temp-buffer
            (kubel-sops-mode)
            (setq kubel-resource dir)
            (cl-letf (((symbol-function 'process-file)
                       (lambda (_program _infile _buffer _display &rest args)
                         (should (equal '("filestatus" "enc.yaml") args))
                         (insert "{\"encrypted\":true}")
                         0)))
              (let ((entries (cadr (kubel-sops--populate-list))))
                (should (equal '("plain.yaml" "sub/enc.yaml") (mapcar #'car entries)))
                (should (equal "plain" (aref (cadr (nth 0 entries)) 1)))
                (should (equal "encrypted" (aref (cadr (nth 1 entries)) 1)))))))
      (delete-directory dir t))))

(ert-deftest kubel--test-sops-plaintext-buffer-protection ()
  (let* ((kubel-sops--edit-directories (list (file-truename (file-name-as-directory temporary-file-directory))))
         (file (make-temp-file "kubel-test")))
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name file)
          (auto-save-mode 1)
          (kubel-sops--protect-plaintext)
          (should backup-inhibited)
          (should-not buffer-auto-save-file-name))
      (delete-file file))))

;; kustomize

(ert-deftest kubel--test-kustomize-listing-and-args ()
  (let ((dir (file-name-as-directory (make-temp-file "kubel-test" t))))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "overlay" dir))
          (write-region "resources: []\n" nil (expand-file-name "kustomization.yaml" dir))
          (write-region "namespace: prod # comment\nnamePrefix: a-\n" nil
                        (expand-file-name "overlay/Kustomization" dir))
          (with-temp-buffer
            (kubel-kustomize-mode)
            (setq kubel-resource dir)
            (let ((entries (cadr (kubel-kustomize--populate-list))))
              (should (equal '("./" "overlay/") (mapcar (lambda (e) (file-name-as-directory (car e))) entries)))
              (should (equal "prod" (aref (cadr (nth 1 entries)) 1)))
              (should (equal "a-" (aref (cadr (nth 1 entries)) 2))))))
      (delete-directory dir t)))
  (should (equal '("--enable-helm")
                 (kubel-kustomize--build-args '("--enable-helm" "--server-side" "--dry-run=server")))))

;; (ert "kubel--test-.*")

(provide 'kubel-test)
;;; kubel-test.el ends here
