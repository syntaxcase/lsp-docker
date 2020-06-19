;;; lsp-docker.el --- LSP Docker integration         -*- lexical-binding: t; -*-

;; Copyright (C) 2019  Ivan Yonchovski

;; Author: Ivan Yonchovski <yyoncho@gmail.com>
;; URL: https://github.com/emacs-lsp/lsp-docker
;; Keywords: languages langserver
;; Version: 1.0.0
;; Package-Requires: ((emacs "25.1") (dash "2.14.1") (lsp-mode "6.2.1"))


;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Run language servers in containers

;;; Code:
(require 'lsp-mode)
(require 'dash)

(defgroup lsp-docker nil
  "lsp-docker"
  :group 'tools
  :tag "Docker Language Server")

(defcustom lsp-docker-executable "docker"
  "The path to a docker-compatible executable"
  :type 'string
  :group 'lsp-docker)

(defun lsp-docker--maybe-funcall (x)
  (if (functionp x)
      (funcall x)
    x))

(defun lsp-docker--uri->path (path-mappings docker-container-name uri)
  "Turn docker URI into host path.
Argument PATH-MAPPINGS dotted pair of (host-path . container-path).
Argument DOCKER-CONTAINER-NAME name to use when running container.
Argument URI the uri to translate."
  (let ((path (lsp--uri-to-path-1 uri)))
    (-if-let ((local . remote) (-first (-lambda ((_ . docker-path))
                                         (s-contains? (lsp-docker--maybe-funcall docker-path)
                                                      path))
                                       path-mappings))
        (s-replace (lsp-docker--maybe-funcall remote) (lsp-docker--maybe-funcall local) path)
      (format "/docker:%s:%s" (lsp-docker--maybe-funcall docker-container-name) path))))

(defun lsp-docker--path->uri (path-mappings path)
  "Turn host PATH into docker uri.
Argument PATH-MAPPINGS dotted pair of (host-path . container-path).
Argument PATH the path to translate."
  (lsp--path-to-uri-1
   (-if-let ((local . remote) (-first (-lambda ((local-path . _))
                                        (unless (functionp local-path)
                                          (s-contains? local-path path)))
                                      path-mappings))
       (s-replace local remote path)
     (-let (((local-fn . remote-fn) (car path-mappings)))
       (s-replace (funcall local-fn) (funcall remote-fn) path)))))


(defvar lsp-docker-container-name-suffix 0
  "Used to prevent collision of container names.")

(defun lsp-docker-launch-new-container (docker-container-name path-mappings docker-image-id server-command)
  "Return the docker command to be executed on host.
Argument DOCKER-CONTAINER-NAME name to use for container.
Argument PATH-MAPPINGS dotted pair of (host-path . container-path).
Argument DOCKER-IMAGE-ID the docker container to run language servers with.
Argument SERVER-COMMAND the language server command to run inside the container."
  (cl-incf lsp-docker-container-name-suffix)
  (split-string
   (--doto (format "%s run --name %s-%d --rm -i %s %s %s"
                   lsp-docker-executable
                   docker-container-name
                   lsp-docker-container-name-suffix
                   (->> path-mappings
                        (-map (-lambda ((path . docker-path))
                                (format "-v %s:%s"
                                        (lsp-docker--maybe-funcall path)
                                        (lsp-docker--maybe-funcall docker-path))))
                        (s-join " "))
                   (lsp-docker--maybe-funcall docker-image-id)
                   server-command))
   " "))

(defun lsp-docker-exec-in-container (docker-container-name path-mappings docker-image-id server-command)
  "Return command to exec into running container.
Argument DOCKER-CONTAINER-NAME name of container to exec into.
Argument SERVER-COMMAND the command to execute inside the running container."
  (split-string
   (format "%s exec -i %s %s" lsp-docker-executable (lsp-docker--maybe-funcall docker-container-name) server-command)))

(cl-defun lsp-docker-register-client (&key server-id
                                           docker-server-id
                                           path-mappings
                                           default-path-mappings
                                           docker-image-id
                                           docker-container-name
                                           priority
                                           server-command
                                           launch-server-cmd-fn)
  "Registers docker clients with lsp"
  (when (and (not path-mappings) (not default-path-mappings))
    (error "one of `:path-mappings' or `:default-path-mappings' must be specified"))

  (if-let ((client (copy-lsp--client (gethash server-id lsp-clients))))
      (let ((path-mappings (if default-path-mappings
                               (cons default-path-mappings path-mappings)
                             path-mappings)))
        (progn
          (setf (lsp--client-server-id client) docker-server-id
                (lsp--client-uri->path-fn client) (-partial #'lsp-docker--uri->path
                                                            path-mappings
                                                            docker-container-name)
                (lsp--client-path->uri-fn client) (-partial #'lsp-docker--path->uri path-mappings)
                (lsp--client-new-connection client) (plist-put
                                                     (lsp-stdio-connection
                                                      (lambda ()
                                                        (funcall (or launch-server-cmd-fn #'lsp-docker-launch-new-container)
                                                                 docker-container-name
                                                                 path-mappings
                                                                 docker-image-id
                                                                 server-command)))
                                                     :test? (lambda (&rest _)
                                                              (-any?
                                                               (-lambda ((dir))
                                                                 (let ((dir (if (functionp dir)
                                                                                (funcall dir)
                                                                              dir)))
                                                                   (f-ancestor-of? dir (buffer-file-name))))
                                                               path-mappings)))
                (lsp--client-priority client) (or priority (lsp--client-priority client)))
          (lsp-register-client client)))
    (user-error "No such client %s" server-id)))

(defvar lsp-docker-default-client-packages
  '(lsp-bash lsp-clients lsp-cpp lsp-css lsp-go
    lsp-html lsp-pyls lsp-typescript)
  "Default list of client packages to load.")

(defvar lsp-docker-default-client-configs
  (list
   (list :server-id 'bash-ls :docker-server-id 'bashls-docker :server-command "bash-language-server start")
   (list :server-id 'clangd :docker-server-id 'clangd-docker :server-command "ccls")
   (list :server-id 'css-ls :docker-server-id 'cssls-docker :server-command "css-languageserver --stdio")
   (list :server-id 'dockerfile-ls :docker-server-id 'dockerfilels-docker :server-command "docker-langserver --stdio")
   (list :server-id 'gopls :docker-server-id 'gopls-docker :server-command "gopls")
   (list :server-id 'html-ls :docker-server-id 'htmls-docker :server-command "html-languageserver --stdio")
   (list :server-id 'pyls :docker-server-id 'pyls-docker :server-command "pyls")
   (list :server-id 'ts-ls :docker-server-id 'tsls-docker :server-command "typescript-language-server --stdio"))
  "Default list of client configurations.")

(cl-defun lsp-docker-init-clients (&key
				   path-mappings
                                   default-path-mappings
				   (priority 10)
				   (client-packages lsp-docker-default-client-packages)
				   (client-configs lsp-docker-default-client-configs))
  "Loads the required client packages and registers the required clients to run with docker."
  (seq-do (lambda (package) (require package nil t)) client-packages)
  (seq-do (-lambda ((&plist :server-id :docker-server-id :server-command :docker-image-id :docker-container-name :launch-server-cmd-fn))
	    (lsp-docker-register-client
	     :server-id server-id
	     :priority priority
	     :docker-server-id docker-server-id
	     :docker-image-id docker-image-id
	     :docker-container-name docker-container-name
	     :server-command server-command
	     :path-mappings path-mappings
             :default-path-mappings default-path-mappings
	     :launch-server-cmd-fn (if launch-server-cmd-fn launch-server-cmd-fn #'lsp-docker-launch-new-container)))
	  client-configs))

(provide 'lsp-docker)
;;; lsp-docker.el ends here
