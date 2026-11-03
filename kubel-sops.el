;;; kubel-sops.el --- SOPS porcelain for kubel -*- lexical-binding: t; -*-

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
;; Keywords: kubernetes k8s tools processes sops
;; URL: https://github.com/abrochard/kubel
;; License: GNU General Public License >= 3
;; Package-Requires: ((kubel "1.0") (transient "0.1.0") (dash "2.12.0") (emacs "26.1"))

;;; Commentary:

;; Manage the SOPS encrypted files of a directory from a kubel-style buffer,
;; using the `sops' CLI, and apply them to the cluster of the buffer.
;;
;; Plaintext is kept out of the disk and of process listings where kubel has
;; a say: decrypted output only lives in a buffer, plaintext being edited is
;; neither backed up nor auto-saved, and values given to `kubel-sops-set' go
;; through stdin, are read without echo and are not kept in any history.

;;; Usage:

;; M-x kubel-sops
;;
;; Prompts for a directory and lists its yaml, json, env, ini and enc files
;; with their encryption status.  Use `R' to switch to another directory.

;;; Shortcuts:

;; On the kubel-sops screen, place your cursor on a file
;;
;; enter => view the decrypted file
;; d => decrypt popup (view/extract/in place/to file)
;; e => edit the file in this Emacs, C-x # when done
;; E => encrypt popup
;; r => rotate popup (new data key, add or remove master keys)
;; K => update the keys from .sops.yaml, asking for confirmation in a terminal
;; s => set a value
;; x => unset a value
;; o => open the .sops.yaml which applies to the file
;; A => apply the decrypted file to the cluster
;; D => diff the decrypted file with the cluster
;; R => set directory
;; C, g, f, M-n, M-p, m, u, M, U, $, b, q => as in kubel

;;; Code:

(require 'kubel)
(require 'server)

(defcustom kubel-sops-program "sops"
  "SOPS binary path."
  :type '(file :must-match t)
  :group 'kubel)

(defcustom kubel-sops-emacsclient-program "emacsclient"
  "Emacsclient binary path, used to edit files in this Emacs."
  :type '(file :must-match t)
  :group 'kubel)

(defcustom kubel-sops-editor nil
  "Editor command for `kubel-sops-edit', run in a terminal buffer.
If nil, files are edited in this Emacs through `emacsclient' and the
server is started if needed.  Otherwise, it is up to this editor to keep
the plaintext from being written elsewhere."
  :type '(choice (const :tag "This Emacs" nil) string)
  :group 'kubel)

(defcustom kubel-sops-file-regexp "\\.\\(ya?ml\\|json\\|env\\|ini\\|enc\\)\\'"
  "Regexp of the file names listed in kubel-sops buffers."
  :type 'regexp
  :group 'kubel)

(defconst kubel-sops--metadata-regexp
  "^sops:\\|\"sops\"[ \t]*:\\|^sops_version=\\|^\\[sops\\]"
  "Regexp of the metadata in an encrypted file of any format.")

(defvar kubel-sops--edit-directories nil
  "Directories holding the plaintext of the running `sops edit' commands.")

;; listing

(defun kubel-sops--file-status (file)
  "Return the encryption status of FILE.
Asking sops needs a process, so it's only done for files with metadata."
  (let ((candidate (with-temp-buffer
                     (insert-file-contents file)
                     (re-search-forward kubel-sops--metadata-regexp nil t))))
    (if (not candidate)
        "plain"
      (let* ((default-directory (file-name-directory file))
             (output (with-temp-buffer
                       (when (eq 0 (process-file kubel-sops-program nil '(t nil) nil
                                                 "filestatus" (file-name-nondirectory file)))
                         (buffer-string))))
             (status (and output (ignore-errors (json-read-from-string output)))))
        (cond ((null status) "invalid")
              ((eq (cdr (assoc 'encrypted status)) t) "encrypted")
              (t "plain"))))))

(defun kubel-sops--list-file-p (file)
  "Return non-nil if FILE is to be listed."
  (and (string-match-p kubel-sops-file-regexp file)
       (not (member (file-name-nondirectory file) '(".sops.yaml" ".sops.yml")))))

(defun kubel-sops--populate-list ()
  "Return the tabulated list format and entries for the current directory."
  (let* ((root (expand-file-name kubel-resource))
         (entrylist
          (cons '("FILE" "STATUS" "TYPE" "MODIFIED")
                (mapcar (lambda (file)
                          (list (file-relative-name file root)
                                (kubel-sops--file-status file)
                                (or (file-name-extension file)
                                    (string-remove-prefix "." (file-name-nondirectory file)))
                                (format-time-string "%Y-%m-%d %H:%M:%S"
                                                    (nth 5 (file-attributes file)))))
                        (kubel--directory-files-recursively root #'kubel-sops--list-file-p)))))
    (list (kubel--get-list-format entrylist) (kubel--get-list-entries entrylist))))

;; running sops

(defun kubel-sops--path (item)
  "Return the absolute file name of ITEM, a file of the list."
  (expand-file-name item (expand-file-name kubel-resource)))

(defun kubel-sops--exec (item args &optional readonly callback)
  "Run sops with ARGS for ITEM, in the directory of ITEM.
Sops looks for .sops.yaml from its working directory upwards, so this
finds the configuration closest to the file.  ARGS has to name the file
with its base name.  READONLY and CALLBACK are as in
`kubel--exec-program-async'.  Stdin is a pipe, so that it can be written
to without being echoed.  Return the process."
  (let ((default-directory (file-name-directory (kubel-sops--path item)))
        (process-connection-type nil))
    (kubel--exec-program-async (format "kubel - sops %s - %s" (car args) item)
                               kubel-sops-program nil args readonly callback)))

(defun kubel-sops--shell-command (item &rest args)
  "Return the shell command to run sops with ARGS for ITEM in its directory."
  (let ((path (kubel-sops--path item)))
    (format "cd %s && %s"
            (shell-quote-argument (file-local-name (file-name-directory path)))
            (mapconcat #'shell-quote-argument
                       (append (list kubel-sops-program) args
                               (list (file-name-nondirectory path)))
                       " "))))

(defun kubel-sops--terminal-check ()
  "Fail if the current directory is remote, terminals are local only."
  (when (file-remote-p (expand-file-name kubel-resource))
    (user-error "This command needs a terminal, which only works on local files")))

;; decrypting

(defun kubel-sops-decrypt (&optional args)
  "View the marked or current files decrypted, in a buffer.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-sops-decrypt-popup)))
  (dolist (item (kubel--marked-or-current-items))
    (kubel-sops--exec item
                      (append '("decrypt") args (list (file-name-nondirectory item)))
                      t
                      (lambda () (goto-char (point-min))))))

(defun kubel-sops-decrypt-in-place (&optional args)
  "Replace the marked or current files with their plaintext.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-sops-decrypt-popup)))
  (let ((items (kubel--marked-or-current-items))
        (list-buffer (current-buffer)))
    (when (yes-or-no-p (format "Write the plaintext of %s to disk? " (string-join items ", ")))
      (dolist (item items)
        (kubel-sops--exec item
                          (append '("decrypt" "--in-place") args (list (file-name-nondirectory item)))
                          nil (kubel--refresh-callback list-buffer))))))

(defun kubel-sops-decrypt-to-file (output &optional args)
  "Write the plaintext of the file under cursor to OUTPUT.
ARGS is the arguments list from transient."
  (interactive (list (read-file-name "Write plaintext to: ")
                     (transient-args 'kubel-sops-decrypt-popup)))
  (let ((item (kubel--get-resource-under-cursor))
        (list-buffer (current-buffer)))
    (kubel-sops--exec item
                      (append (list "decrypt" (concat "--output=" (file-local-name (expand-file-name output))))
                              args (list (file-name-nondirectory item)))
                      nil (kubel--refresh-callback list-buffer))))

;; changing files

(defun kubel-sops-encrypt (&optional args)
  "Encrypt the marked or current files in place.
Without keys in ARGS, the arguments list from transient, sops uses the
creation rules of .sops.yaml."
  (interactive (list (transient-args 'kubel-sops-encrypt-popup)))
  (let ((list-buffer (current-buffer)))
    (dolist (item (kubel--marked-or-current-items))
      (kubel-sops--exec item
                        (append '("encrypt" "--in-place") args (list (file-name-nondirectory item)))
                        nil (kubel--refresh-callback list-buffer)))))

(defun kubel-sops-rotate (&optional args)
  "Rotate the data key of the marked or current files, in place.
ARGS is the arguments list from transient."
  (interactive (list (transient-args 'kubel-sops-rotate-popup)))
  (let ((items (kubel--marked-or-current-items))
        (list-buffer (current-buffer)))
    (when (y-or-n-p (format "Rotate the data key of %s? " (string-join items ", ")))
      (dolist (item items)
        (kubel-sops--exec item
                          (append '("rotate" "--in-place") args (list (file-name-nondirectory item)))
                          nil (kubel--refresh-callback list-buffer))))))

(defun kubel-sops-update-keys ()
  "Update the keys of the file under cursor from .sops.yaml.
Runs in a terminal, where sops shows the changes and asks to confirm them."
  (interactive)
  (kubel-sops--terminal-check)
  (let* ((item (kubel--get-resource-under-cursor))
         (path (kubel-sops--path item))
         (default-directory (file-name-directory path)))
    (kubel--run-in-term (format "kubel-sops-updatekeys:%s" item) kubel-sops-program
                        (list "updatekeys" (file-name-nondirectory path)))))

(defun kubel-sops-set (index value &optional raw)
  "Set INDEX, such as [\"key\"][0], of the file under cursor to VALUE.
VALUE is a string.  With prefix argument RAW, it is JSON instead.
It goes through stdin to stay out of process listings and logs."
  (interactive
   (list (read-string "Index, such as [\"key\"][0]: ")
         (read-passwd (if current-prefix-arg "JSON value: " "Value: "))
         current-prefix-arg))
  (let* ((item (kubel--get-resource-under-cursor))
         (process (kubel-sops--exec item
                                    (list "set" "--value-stdin" (file-name-nondirectory item) index)
                                    nil (kubel--refresh-callback (current-buffer)))))
    (process-send-string process (if raw value (json-encode-string value)))
    (process-send-eof process)
    (clear-string value)))

(defun kubel-sops-unset (index)
  "Unset INDEX, such as [\"key\"][0], of the file under cursor."
  (interactive "sIndex to unset, such as [\"key\"][0]: ")
  (let ((item (kubel--get-resource-under-cursor)))
    (when (y-or-n-p (format "Unset %s in %s? " index item))
      (kubel-sops--exec item
                        (list "unset" (file-name-nondirectory item) index)
                        nil (kubel--refresh-callback (current-buffer))))))

;; editing

(defun kubel-sops--in-edit-directory-p (file)
  "Return non-nil if FILE is in one of `kubel-sops--edit-directories'."
  (let ((truename (file-truename file)))
    (seq-some (lambda (dir) (string-prefix-p dir truename)) kubel-sops--edit-directories)))

(defun kubel-sops--protect-plaintext ()
  "Keep the plaintext of a buffer visiting a `sops edit' file off the disk.
Otherwise `backup-directory-alist' or `auto-save-file-name-transforms'
would make copies outside of the temporary directory of sops."
  (when (and buffer-file-name (kubel-sops--in-edit-directory-p buffer-file-name))
    (setq-local backup-inhibited t)
    (setq-local make-backup-files nil)
    (setq-local create-lockfiles nil)
    (auto-save-mode -1)))

(defun kubel-sops--edit-finished (directory)
  "Clean up after the `sops edit' which used DIRECTORY."
  (dolist (buffer (buffer-list))
    (let ((file (buffer-file-name buffer)))
      (when (and file (string-prefix-p directory (file-truename file)))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))))
  (setq kubel-sops--edit-directories (delete directory kubel-sops--edit-directories))
  (unless kubel-sops--edit-directories
    (remove-hook 'find-file-hook #'kubel-sops--protect-plaintext))
  (ignore-errors (delete-directory directory t)))

(defun kubel-sops--emacsclient-command ()
  "Return the editor command opening files in this Emacs."
  (unless (server-running-p) (server-start))
  (format "%s %s"
          (shell-quote-argument (or (executable-find kubel-sops-emacsclient-program)
                                    (user-error "Cannot find `%s'" kubel-sops-emacsclient-program)))
          (shell-quote-argument
           (if server-use-tcp
               (concat "--server-file=" (expand-file-name server-name server-auth-dir))
             (concat "--socket-name=" (expand-file-name server-name server-socket-dir))))))

(defun kubel-sops-edit ()
  "Edit the file under cursor with `sops edit', \\[server-edit] when done.
Sops decrypts to a temporary file, which is removed afterwards, and
encrypts it again if it changed.  It runs in a terminal buffer as it asks
what to do there when the edited file is invalid."
  (interactive)
  (kubel-sops--terminal-check)
  (let* ((item (kubel--get-resource-under-cursor))
         (path (kubel-sops--path item))
         (name (format "kubel-sops-edit:%s" item))
         (running (get-buffer (format "*%s*" name))))
    (if (and running (get-buffer-process running))
        (pop-to-buffer-same-window running)
      (let* ((default-directory (file-name-directory path))
             (editor (or kubel-sops-editor (kubel-sops--emacsclient-command)))
             (tmpdir (file-name-as-directory
                      (file-truename (make-temp-file "kubel-sops-" t))))
             (process-environment (append (list (concat "SOPS_EDITOR=" editor)
                                                (concat "TMPDIR=" tmpdir))
                                          process-environment)))
        (push tmpdir kubel-sops--edit-directories)
        (add-hook 'find-file-hook #'kubel-sops--protect-plaintext)
        (kubel--run-in-term name kubel-sops-program (list "edit" (file-name-nondirectory path)))
        (add-function :after (process-sentinel (get-buffer-process (format "*%s*" name)))
                      (lambda (process _event)
                        (unless (process-live-p process)
                          (kubel-sops--edit-finished tmpdir))))))))

(defun kubel-sops-open-config ()
  "Open the .sops.yaml which applies to the file under cursor."
  (interactive)
  (let* ((path (kubel-sops--path (kubel--get-resource-under-cursor)))
         (file (seq-some (lambda (name)
                           (let ((dir (locate-dominating-file path name)))
                             (when dir (expand-file-name name dir))))
                         '(".sops.yaml" ".sops.yml"))))
    (if file
        (find-file file)
      (user-error "No .sops.yaml above %s" path))))

;; cluster

(defun kubel-sops-apply (&optional args)
  "Apply the decrypted marked or current files to the cluster.
ARGS is the arguments list from transient.  The plaintext goes through a
pipe and doesn't reach the disk."
  (interactive (list (transient-args 'kubel-sops-cluster-popup)))
  (let ((items (kubel--marked-or-current-items)))
    (when (y-or-n-p (format "Apply decrypted %s to context %s? " (string-join items ", ") kubel-context))
      (dolist (item items)
        (kubel--exec-pipe-to-kubectl (format "kubel - sops apply - %s" item)
                                     (kubel-sops--shell-command item "decrypt")
                                     (append '("apply" "-f" "-") args))))))

(defun kubel-sops-diff ()
  "Diff the decrypted marked or current files with the cluster.
Kubectl masks the data of secrets in its diff."
  (interactive)
  (dolist (item (kubel--marked-or-current-items))
    (with-current-buffer
        (process-buffer
         (kubel--exec-pipe-to-kubectl (format "kubel - sops diff - %s" item)
                                      (kubel-sops--shell-command item "decrypt")
                                      '("diff" "-f" "-")
                                      (lambda () (message "No differences"))))
      (diff-mode))))

(defun kubel-sops-set-directory (directory)
  "List the files of DIRECTORY."
  (interactive "DList files of directory: ")
  (let ((parent-buffer (current-buffer)))
    (with-current-buffer (clone-buffer)
      (setq kubel--parent-buffer parent-buffer)
      (setq kubel-resource (abbreviate-file-name (file-name-as-directory (expand-file-name directory))))
      (setq kubel--selected-items '())
      (switch-to-buffer (current-buffer))
      (kubel-refresh))))

;; popups

(transient-define-prefix kubel-sops-decrypt-popup ()
  "Kubel SOPS Decrypt Menu"
  ["Arguments"
   ("-e" "Extract, such as [\"key\"][0]" "--extract=")
   ("-t" "Output type" "--output-type=" :choices ("yaml" "json" "dotenv" "ini" "binary"))
   ("-m" "Ignore MAC" "--ignore-mac")]
  ["Actions"
   ("d" "View" kubel-sops-decrypt)
   ("f" "To file" kubel-sops-decrypt-to-file)
   ("i" "In place" kubel-sops-decrypt-in-place)])

(transient-define-prefix kubel-sops-encrypt-popup ()
  "Kubel SOPS Encrypt Menu"
  ["Keys, default to the creation rules of .sops.yaml"
   ("-a" "age recipients" "--age=")
   ("-p" "PGP fingerprints" "--pgp=")
   ("-k" "AWS KMS ARNs" "--kms=")
   ("-g" "GCP KMS IDs" "--gcp-kms=")
   ("-z" "Azure Key Vault URLs" "--azure-kv=")
   ("-v" "Vault transit URIs" "--hc-vault-transit=")]
  ["What to encrypt"
   ("-r" "Encrypted regex" "--encrypted-regex=")
   ("-R" "Unencrypted regex" "--unencrypted-regex=")
   ("-s" "Encrypted suffix" "--encrypted-suffix=")
   ("-S" "Unencrypted suffix" "--unencrypted-suffix=")]
  ["Actions"
   ("E" "Encrypt in place" kubel-sops-encrypt)])

(transient-define-prefix kubel-sops-rotate-popup ()
  "Kubel SOPS Rotate Menu"
  [["Add keys"
    ("+a" "age recipients" "--add-age=")
    ("+p" "PGP fingerprints" "--add-pgp=")
    ("+k" "AWS KMS ARNs" "--add-kms=")
    ("+g" "GCP KMS IDs" "--add-gcp-kms=")
    ("+z" "Azure Key Vault URLs" "--add-azure-kv=")
    ("+v" "Vault transit URIs" "--add-hc-vault-transit=")]
   ["Remove keys"
    ("-a" "age recipients" "--rm-age=")
    ("-p" "PGP fingerprints" "--rm-pgp=")
    ("-k" "AWS KMS ARNs" "--rm-kms=")
    ("-g" "GCP KMS IDs" "--rm-gcp-kms=")
    ("-z" "Azure Key Vault URLs" "--rm-azure-kv=")
    ("-v" "Vault transit URIs" "--rm-hc-vault-transit=")]]
  ["Actions"
   ("r" "Rotate in place" kubel-sops-rotate)])

(transient-define-prefix kubel-sops-cluster-popup ()
  "Kubel SOPS Cluster Menu"
  ["Arguments"
   ("-d" "Server dry run" "--dry-run=server")
   ("-s" "Server side" "--server-side")]
  ["Actions"
   ("A" "Apply" kubel-sops-apply)
   ("D" "Diff" kubel-sops-diff)])

(transient-define-prefix kubel-sops-help-popup ()
  "Kubel SOPS Menu"
  [["Files"
    ("RET" "View decrypted" kubel-sops-decrypt)
    ("d" "Decrypt..." kubel-sops-decrypt-popup)
    ("e" "Edit" kubel-sops-edit)
    ("E" "Encrypt..." kubel-sops-encrypt-popup)
    ("r" "Rotate..." kubel-sops-rotate-popup)
    ("K" "Update keys" kubel-sops-update-keys)
    ("s" "Set value" kubel-sops-set)
    ("x" "Unset value" kubel-sops-unset)
    ("o" "Open .sops.yaml" kubel-sops-open-config)]
   ["Cluster"
    ("A" "Apply..." kubel-sops-cluster-popup)
    ("D" "Diff" kubel-sops-diff)
    ("C" "Set context" kubel-set-context)]
   ["Settings"
    ("R" "Set directory" kubel-sops-set-directory)
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
(defvar kubel-sops-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") 'kubel-sops-decrypt)
    (define-key map (kbd "h") 'kubel-sops-help-popup)
    (define-key map (kbd "?") 'kubel-sops-help-popup)
    (define-key map (kbd "R") 'kubel-sops-set-directory)
    (define-key map (kbd "d") 'kubel-sops-decrypt-popup)
    (define-key map (kbd "e") 'kubel-sops-edit)
    (define-key map (kbd "E") 'kubel-sops-encrypt-popup)
    (define-key map (kbd "r") 'kubel-sops-rotate-popup)
    (define-key map (kbd "K") 'kubel-sops-update-keys)
    (define-key map (kbd "s") 'kubel-sops-set)
    (define-key map (kbd "x") 'kubel-sops-unset)
    (define-key map (kbd "o") 'kubel-sops-open-config)
    (define-key map (kbd "A") 'kubel-sops-cluster-popup)
    (define-key map (kbd "D") 'kubel-sops-diff)
    ;; kubectl-only commands that don't apply to files
    (dolist (key '("n" "F" "y" "p" "!" "j" "S" "l" "c" "I" "k"))
      (define-key map (kbd key) 'undefined))
    map)
  "Keymap for `kubel-sops-mode'.")

(define-derived-mode kubel-sops-mode kubel-mode "Kubel-SOPS"
  "Special mode for kubel SOPS buffers."
  (setq kubel--buffer-prefix "kubel-sops")
  (setq kubel--populate-function #'kubel-sops--populate-list))

;;;###autoload
(defun kubel-sops (directory)
  "Invoke the kubel SOPS buffer, listing the files of DIRECTORY."
  (interactive "DList files of directory: ")
  (kubel--open-in-mode #'kubel-sops-mode
                       (abbreviate-file-name (file-name-as-directory (expand-file-name directory)))
                       nil ""))

(provide 'kubel-sops)
;;; kubel-sops.el ends here
