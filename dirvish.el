;;; dirvish.el --- A modern file manager based on dired mode -*- lexical-binding: t -*-
;; Copyright (C) 2021-2022 Alex Lu

;; Author : Alex Lu <https://github.com/alexluigit>
;; Version: 1.8.14
;; Keywords: files, convenience
;; Homepage: https://github.com/alexluigit/dirvish
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1") (transient "0.3.7"))

;; This file is not part of GNU Emacs.

;;; Commentary:
;; A minimalistic yet versatile file manager based on Dired.
;; This package gives Dired the following features:
;;
;; - Multiple window layouts
;; - Always available file preview
;; - Isolated sessions
;; - A modern and composable user interface

;;; Code:

(require 'dired)
(require 'so-long)
(require 'ansi-color)
(require 'tramp)
(require 'transient)
(eval-when-compile (require 'find-dired))
(declare-function dirvish-fd "dirvish-fd")
(declare-function dirvish-subtree--prefix-length "dirvish-subtree")

;;;; User Options

(defgroup dirvish nil "A better Dired." :group 'dired)

(defcustom dirvish-attributes '()
  "File attributes such as `file-size' showing in Dirvish file lines.
You can get all available attributes in `dirvish--available-attrs'.
See `dirvish-define-attribute'."
  :group 'dirvish :type '(repeat (symbol :tag "Dirvish attribute")))

(defcustom dirvish-preview-dispatchers '(image gif video audio epub archive pdf)
  "List of preview dispatchers.
Preview dispatchers are defined by `dirvish-define-preview'.  It
holds a function that takes current filename and preview window
as arguments and gets called at runtime.  It controls how the
preview content for certain filetypes are generated, or it can
decline to handle the file name and leaving it for future
dispatchers.  If none of the dispatchers can handle the preview,
the fallback dispatcher named `default' is used.  For details see
`dirvish-preview-dispatch'."
  :group 'dirvish :type '(repeat (symbol :tag "Dirvish preview dispatcher")))

(defcustom dirvish-preview-disabled-exts '("iso" "bin" "exe" "gpg" "elc" "eln")
  "Do not preview files end with these extensions."
  :group 'dirvish :type '(repeat (string :tag "File name extension")))

(defvar dirvish--auto-cache-timer nil)
(defcustom dirvish-auto-cache-threshold '(500 . 4)
  "Generate cache images automatically.
The value should be a cons cell (FILES . PROCS).  Directories
that include number of files less than FILES are cached
automatically, set it to 0 disables auto caching.  PROCS is the
max number of cache processes."
  :group 'dirvish
  :type '(cons (integer :tag "Max number of directory files")
               (integer :tag "Max number of cache process"))
  :set (lambda (k v)
         (set k v)
         (and (timerp dirvish--auto-cache-timer)
              (cancel-timer dirvish--auto-cache-timer))
         (unless (eq (car v) 0)
           (setq dirvish--auto-cache-timer
                 (run-with-timer 0 0.25 #'dirvish--autocache)))))

(defcustom dirvish-cache-dir
  (expand-file-name "dirvish/" user-emacs-directory)
  "Preview / thumbnail cache directory for dirvish."
  :group 'dirvish :type 'string)

(defcustom dirvish-default-layout '(1 0.11 0.55)
  "Default layout recipe for fullscreen Dirvish sessions.
The value has the form (DEPTH MAX-PARENT-WIDTH PREVIEW-WIDTH).
DEPTH controls the number of windows displaying parent directories.
  It can be 0 if you don't need the parent directories.
MAX-PARENT-WIDTH controls the max width allocated to each parent windows.
PREVIEW-WIDTH controls the width allocated to preview window.
The default value gives us an 1:3:5 (approximately) pane ratio.
Also see `dirvish-layout-recipes' in `dirvish-extras.el'."
  :group 'dirvish :type '(list (integer :tag "number of parent windows")
                               (float :tag "max width of parent windows")
                               (float :tag "width of preview windows")))

(defface dirvish-hl-line
  '((((class color) (background light)) :background "#8eecf4" :extend t)
    (((class color) (background dark)) :background "#004065" :extend t))
  "Face for Dirvish line highlighting."
  :group 'dirvish)

(defcustom dirvish-mode-line-position 'default
  "The way to place the mode line in fullscreen Dirvish sessions.
The valid value are:
- disable: Do not show the mode line
- default: Display the mode line across directory panes.
- global:  Make the mode-line span all panes."
  :group 'dirvish :type '(choice (const :tag "Do not show the mode line" disable)
                                 (const :tag "Display the mode line across directory panes" default)
                                 (const :tag "Make the mode line span all panes" global)))

(defcustom dirvish-header-line-position 'default
  "Like `dirvish-mode-line-position', but for header line."
  :group 'dirvish :type 'symbol)

(defcustom dirvish-mode-line-height '(25 . 30)
  "Height of Dirvish's mode line.
The value should be a cons cell (H-DIRED . H-DIRVISH), where
H-DIRED and H-DIRVISH represent the height in single window
session and fullscreen session respectively.  See
`dirvish--bar-image' for details."
  :group 'dirvish
  :type '(cons (integer :tag "Mode line height in fullscreen sessions.")
               (integer :tag "Mode line height in single window sessions.")))

(defcustom dirvish-header-line-height '(25 . 35)
  "Like `dirvish-mode-line-height', but for header line."
  :group 'dirvish :type 'cons)

(defun dirvish--mode-line-fmt-setter (fmt &optional header)
  "Compose the `mode-line-format' or header-line (if HEADER) from FMT."
  (cl-labels ((expand (part)
                (cl-loop for s in (plist-get fmt part) collect
                         (if (stringp s) s `(:eval (,(intern (format "dirvish-%s-ml" s)) dv)))))
              (get-font-scale ()
                (let* ((face (if header 'header-line 'mode-line-inactive))
                       (defualt (face-attribute 'default :height))
                       (ml-height (face-attribute face :height)))
                  (cond ((floatp ml-height) ml-height)
                        ((integerp ml-height) (/ (float ml-height) defualt))
                        (t 1)))))
    `((:eval
       (let* ((dv (dirvish-prop :dv))
              (buf (alist-get (dv-index-dir dv) (dv-roots dv) nil nil #'equal))
              (scale ,(get-font-scale))
              (win-width (floor (/ (window-width) scale)))
              (str-l "") (str-r "") (len-r 0))
         (when (buffer-live-p buf)
           (setq str-l (format-mode-line ',(or (expand :left) mode-line-format) nil nil buf))
           (setq str-r (format-mode-line ',(expand :right) nil nil buf))
           (setq len-r (string-width str-r)))
         (concat
          (dirvish--bar-image (dv-layout dv) ,header)
          (if (< (+ (string-width str-l) len-r) win-width)
              str-l
            (let ((trim (1- (- win-width len-r))))
              (if (>= trim 0) (substring str-l 0 (min trim (1- (length str-l)))) "")))
          (propertize
           " " 'display
           `((space :align-to (- (+ right right-fringe right-margin)
                                 ,(ceiling (* scale (string-width str-r)))))))
          str-r))))))

(defcustom dirvish-mode-line-format
  '(:left (sort omit symlink) :right (index))
  "Mode line SEGMENTs aligned to left/right respectively.
Set it to nil to use the default `mode-line-format'.  SEGMENT is
a mode line segment defined by `dirvish-define-mode-line' or a
string.  See `dirvish--available-mode-line-segments'."
  :group 'dirvish :type 'plist
  :set (lambda (k v) (set k (dirvish--mode-line-fmt-setter v))))

(defcustom dirvish-header-line-format
  '(:left (path) :right ())
  "Like `dirvish-mode-line-format', but for header line ."
  :group 'dirvish :type 'plist
  :set (lambda (k v) (set k (dirvish--mode-line-fmt-setter v t))))

(defcustom dirvish-hide-details t
  "Whether to hide detailed information on session startup.
The value can be a boolean or a function that takes current
Dirvish session as its argument."
  :group 'dirvish :type '(choice (const :tag "Always hide details" t)
                                 (const :tag "Never hide details" nil)
                                 (function :tag "Custom function")))

(defconst dirvish-image-exts '("webp" "wmf" "pcx" "xif" "wbmp" "vtf" "tap" "s1j" "sjp" "sjpg" "s1g" "sgi" "sgif" "s1n" "spn" "spng" "xyze" "rgbe" "hdr" "b16" "mdi" "apng" "ico" "pgb" "rlc" "mmr" "fst" "fpx" "fbs" "dxf" "dwg" "djv" "uvvg" "uvg" "uvvi" "uvi" "azv" "psd" "tfx" "t38" "svgz" "svg" "pti" "btf" "btif" "ktx2" "ktx" "jxss" "jxsi" "jxsc" "jxs" "jxrs" "jxra" "jxr" "jxl" "jpf" "jpx" "jpgm" "jpm" "jfif" "jhc" "jph" "jpg2" "jp2" "jls" "hsj2" "hej2" "heifs" "heif" "heics" "heic" "fts" "fit" "fits" "emf" "drle" "cgm" "dib" "bmp" "hif" "avif" "avcs" "avci" "exr" "fax" "icon" "ief" "jpg" "macp" "pbm" "pgm" "pict" "png" "pnm" "ppm" "ras" "rgb" "tga" "tif" "tiff" "xbm" "xpm" "xwd" "jpe" "jpeg"))
(defconst dirvish-audio-exts '("ape" "stm" "s3m" "ra" "rm" "ram" "wma" "wax" "m3u" "med" "669" "mtm" "m15" "uni" "ult" "mod" "mka" "flac" "axa" "kar" "midi" "mid" "s1m" "smp" "smp3" "rip" "multitrack" "ecelp9600" "ecelp7470" "ecelp4800" "vbk" "pya" "lvp" "plj" "dtshd" "dts" "mlp" "eol" "uvva" "uva" "koz" "xhe" "loas" "sofa" "smv" "qcp" "psid" "sid" "spx" "opus" "ogg" "oga" "mp1" "mpga" "m4a" "mxmf" "mhas" "l16" "lbc" "evw" "enw" "evb" "evc" "dls" "omg" "aa3" "at3" "atx" "aal" "acn" "awb" "amr" "ac3" "ass" "aac" "adts" "726" "abs" "aif" "aifc" "aiff" "au" "mp2" "mp3" "mp2a" "mpa" "mpa2" "mpega" "snd" "vox" "wav"))
(defconst dirvish-video-exts '("f4v" "rmvb" "wvx" "wmx" "wmv" "wm" "asx" "mk3d" "mkv" "fxm" "flv" "axv" "webm" "viv" "yt" "s1q" "smo" "smov" "ssw" "sswf" "s14" "s11" "smpg" "smk" "bk2" "bik" "nim" "pyv" "m4u" "mxu" "fvt" "dvb" "uvvv" "uvv" "uvvs" "uvs" "uvvp" "uvp" "uvvu" "uvu" "uvvm" "uvm" "uvvh" "uvh" "ogv" "m2v" "m1v" "m4v" "mpg4" "mp4" "mjp2" "mj2" "m4s" "3gpp2" "3g2" "3gpp" "3gp" "avi" "mov" "movie" "mpe" "mpeg" "mpegv" "mpg" "mpv" "qt" "vbs"))
(defcustom dirvish-open-with-programs
  `((,dirvish-audio-exts . ("mpv" "%f"))
    (,dirvish-video-exts . ("mpv" "%f")))
  "Association list of mimetype and external program for `find-file'.
Each element is of the form (EXTS . (CMD . ARGS)).  EXTS is a
list of file name extensions.  Once the EXTS is matched with
FILENAME in `find-file', a subprocess according to CMD and its
ARGS is issued to open the file outside of Emacs.  The special
placeholder \"%f\" in the ARGS is replaced by the FILENAME at
runtime.  Set it to nil disables this feature."
  :group 'dirvish
  :type '(alist :key-type ((repeat string) :tag "File mimetype or extensions")
                :value-type ((repeat string) :tag "External command and args")))

(define-obsolete-variable-alias 'dirvish-keep-alive-on-quit 'dirvish-reuse-session "Jul 04, 2022")
(defcustom dirvish-reuse-session nil
  "Whether to reuse the hidden sessions.
If this value is non-nil, Dirvish keeps the last buffer of
the (single window) sessions alive on exit.  These hidden
sessions can be reused in the future by command `dirvish' or
`dired-jump'.  A fullscreen session is always reused."
  :group 'dirvish :type 'boolean)

(defcustom dirvish-whitelist-host-regex nil
  "Regexp of host names that always enable extra features."
  :group 'dirvish :type 'string)

(defvar dirvish-activation-hook nil
  "Hook functions to be executed on session activation.")

(defvar dirvish-deactivation-hook nil
  "Hook functions to be executed on session deactivation.")

(defvar dirvish-after-revert-hook nil
  "Hook functions to be executed after `dirvish-revert'.")

(defvar dirvish-find-entry-hook nil
  "Hook functions to be executed after `dirvish--find-entry'.
Each function takes DV, ENTRY and BUFFER as its arguments.")

(defvar dirvish-setup-hook nil
  "Hook functions to be executed after `dirvish--print-directory'.")

;;;; Internal variables

(defvar dirvish-advice-alist
  '((advice dired                             dirvish-dired-ad               :override)
    (advice dired-jump                        dirvish-dired-jump-ad          :override)
    (advice dired-find-file                   dirvish-find-entry-ad          :override)
    (advice dired-find-alternate-file         dirvish-find-entry-ad          :override)
    (advice dired-find-file-other-window      dirvish-find-file-other-win-ad :override)
    (advice dired-other-window                dirvish-dired-other-window-ad  :override)
    (advice dired-other-tab                   dirvish-dired-other-tab-ad     :override)
    (advice dired-other-frame                 dirvish-dired-other-frame-ad   :override)
    (advice dired-up-directory                dirvish-up-directory-ad        :override)
    (advice dired-dwim-target-next            dirvish-dwim-target-next-ad    :override)
    (advice wdired-change-to-wdired-mode      dirvish-wdired-enter-ad        :after)
    (advice wdired-exit                       dirvish-wdired-exit-ad         :after)
    (advice wdired-finish-edit                dirvish-wdired-exit-ad         :after)
    (advice wdired-abort-changes              dirvish-wdired-exit-ad         :after)
    (advice find-dired-sentinel               dirvish-find-dired-sentinel-ad :after)
    (advice find-file                         dirvish-find-file-ad           :around)
    (advice recentf-track-opened-file         dirvish-ignore-ad              :around)
    (advice recentf-track-closed-file         dirvish-ignore-ad              :around)
    (advice winner-save-old-configurations    dirvish-ignore-ad              :around)
    (advice meow--update-cursor               dirvish-ignore-ad              :around)
    (advice flycheck-buffer                   dirvish-ignore-ad              :around)
    (advice lsp-deferred                      dirvish-ignore-ad              :around)
    (hook   window-selection-change-functions dirvish-reclaim)
    (hook   minibuffer-exit-hook              dirvish-deactivate-minibuffer-h)
    (hook   tab-bar-tab-pre-close-functions   dirvish-deactivate-tab-h)
    (hook   delete-frame-functions            dirvish-deactivate-frame-h)))
(defvar dirvish-scopes
  '(:tab tab-bar--current-tab-index :frame selected-frame :mini active-minibuffer-window))
(defvar dirvish-attrs-library
  '((dirvish-extras   file-size)
    (dirvish-vc       vc-state git-msg)
    (dirvish-collapse collapse)
    (dirvish-icons    all-the-icons vscode-icon)
    (dirvish-subtree  subtree-state)))
(defconst dirvish--dired-free-space
  (or (not (boundp 'dired-free-space)) (eq (bound-and-true-p dired-free-space) 'separate)))
(defconst dirvish--debouncing-delay 0.02)
(defconst dirvish--dir-tail-regex (concat (file-name-as-directory (getenv "HOME")) "\\|\\/$\\|^\\/"))
(defconst dirvish--preview-img-scale 0.92)
(defconst dirvish--tramp-preview-cmd
  "head -n 1000 %s 2>/dev/null || ls -Alh --group-directories-first %s 2>/dev/null &")
(defconst dirvish--saved-new-tab-choice tab-bar-new-tab-choice)
(defconst dirvish--builtin-attrs '(hl-line symlink-target))
(defconst dirvish--os-windows-p (memq system-type '(windows-nt ms-dos)))
(defconst dirvish--no-update-preview-cmds '(scroll-other-window scroll-other-window-down))
(defconst dirvish--cache-embedded-video-thumb
  (string-match "prefer embedded image" (shell-command-to-string "ffmpegthumbnailer -h")))
(defconst dirvish--cache-img-fns
  (cl-loop for dp in '(image video epub) collect (intern (format "dirvish-%s-preview-dp" dp))))
(defconst dirvish--search-switches
  (dirvish--mode-line-fmt-setter '(:left (search-switches) :right (search-time pwd " ")) t))
(defconst dirvish--img-always-cache-exts '("heic"))
(defconst dirvish--img-cache-threshold (* 1024 1024 0.4))
(defvar recentf-list)
(defvar dirvish--hash (make-hash-table))
(defvar dirvish--available-attrs '())
(defvar dirvish--available-mode-line-segments '())
(defvar dirvish--cache-pool '())
(defvar-local dirvish--props '())
(defvar-local dirvish--attrs-hash nil)
(put 'dired-subdir-alist 'permanent-local t)

;;;; Helpers

(defmacro dirvish-prop (prop &rest body)
  "Retrive PROP from `dirvish--props'.
Set the PROP with BODY if given."
  (declare (indent defun))
  `(let* ((pair (assq ,prop dirvish--props)) (val (cdr pair)))
     ,(if body `(prog1 (setq val ,@body)
                  (if pair (setcdr (assq ,prop dirvish--props) val)
                    (push (cons ,prop val) dirvish--props)))
        `val)))

(defmacro dirvish-debounce (label &rest body)
  "Debouncing the execution of BODY.
The BODY runs after the idle time `dirvish--debouncing-delay'.
Multiple calls under the same LABEL are ignored."
  (declare (indent defun))
  (let* ((timer (intern (format "dirvish-%s-debouncing-timer" label)))
         (do-once `(lambda () (unwind-protect ,@body (setq ,timer nil)))))
    `(progn
       (defvar ,timer nil)
       (unless (timerp ,timer)
         (setq ,timer (run-with-idle-timer dirvish--debouncing-delay nil ,do-once))))))

(defmacro dirvish-with-no-dedication (&rest body)
  "Run BODY after undedicating window."
  (declare (debug (&rest form)))
  `(progn
     (let* ((window (get-buffer-window (current-buffer)))
            (dedicated (window-dedicated-p window)))
       (set-window-dedicated-p window nil)
       ,@body
       (set-window-dedicated-p window dedicated))))

(defun dirvish--cache-path-for-file (file type &optional ext no-mkdir)
  "Get FILE's cache path.
TYPE is either a string indicating the subdir of
`dirvish-cache-dir' to use or a number indicating the subdir is
\"images/TYPE\".  The EXT, such as \".jpg\", is attached to FILE.
A new directory is created unless NO-MKDIR."
  (let* ((base (if (numberp type) (concat "images/" (number-to-string type)) type))
         (file (if dirvish--os-windows-p
                   (concat "/" (replace-regexp-in-string ":" "" file)) file))
         (cache (concat dirvish-cache-dir base file)))
    (and (not no-mkdir) (not (file-exists-p cache))
         (make-directory (file-name-directory cache) t))
    (concat cache ext)))

(defun dirvish-apply-ansicolor-h (_win pos)
  "Update dirvish ansicolor in preview window from POS."
  (ansi-color-apply-on-region
   pos (save-excursion (goto-char pos) (forward-line (frame-height)) (point))))

(defmacro dirvish--hide-dired-header (&rest body)
  "Execute BODY then hide the Dired header."
  `(progn
     (remove-overlays (point-min) (point-max) 'dirvish-remove-header t)
     ,@body
     (save-excursion
       (goto-char (point-min))
       (let ((o (make-overlay
                 (point) (progn (forward-line (if dirvish--dired-free-space 2 1)) (point)))))
         (overlay-put o 'dirvish-remove-header t)
         (overlay-put o 'invisible t)))))

(defun dirvish--display-buffer (buffer alist)
  "Try displaying BUFFER with ALIST.
This splits the window at the designated side of the frame.
ALIST is window arguments passed to `window--display-buffer'."
  (let* ((side (cdr (assq 'side alist)))
         (window-configuration-change-hook nil)
         (width (or (cdr (assq 'window-width alist)) 0.5))
         (height (cdr (assq 'window-height alist)))
         (size (or height (ceiling (* (frame-width) width))))
         (split-width-threshold 0)
         (mode-line-format nil)
         (ignore-window-parameters t)
         (new-window (split-window-no-error nil size side)))
    (window--display-buffer buffer new-window 'window alist)))

(defun dirvish--normalize-util-windows (windows)
  "Normalize the size of utility WINDOWS, like header line window."
  (when (> emacs-major-version 28)
    (dolist (win windows)
      (let ((window-safe-min-height 0)
            (window-resize-pixelwise t))
        (fit-window-to-buffer win 2 1)))))

(defun dirvish--kill-buffer (buffer)
  "Kill BUFFER when it is a live one."
  (and (buffer-live-p buffer) (kill-buffer buffer)))

(defun dirvish--get-project-root ()
  "Get root path of current project."
  (when-let ((pj (project-current)))
    (car (with-no-warnings (project-roots pj)))))

(defun dirvish--get-parent-path (path)
  "Get parent directory of PATH."
  (file-name-directory (directory-file-name (expand-file-name path))))

(defun dirvish--append-metadata (metadata completions)
  "Append METADATA for minibuffer COMPLETIONS."
  (let ((entry (if (functionp metadata)
                   `(metadata (annotation-function . ,metadata))
                 `(metadata (category . ,metadata)))))
    (lambda (string pred action)
      (if (eq action 'metadata)
          entry
        (complete-with-action action completions string pred)))))

(defun dirvish--host-in-whitelist-p (&optional vec)
  "Check if the TRAMP connection VEC should be dominated by Dirvish."
  (when-let ((vec (or vec (dirvish-prop :tramp))))
    (or (tramp-local-host-p vec)
        (and dirvish-whitelist-host-regex
             (string-match-p dirvish-whitelist-host-regex (nth 4 vec)))
        (and (tramp-get-method-parameter vec 'tramp-direct-async)
             (tramp-get-connection-property vec "direct-async-process" nil)))))

(defun dirvish--reuse-session (file &optional fullscreen)
  "Reuse the first hidden Dirvish session and find FILE in it.
Only do it when `dirvish-reuse-session' or FULLSCREEN is non-nil."
  (when (or dirvish-reuse-session fullscreen)
    (cl-loop for dv-name in (dirvish-get-all 'name nil t)
             for dv = (gethash dv-name dirvish--hash)
             for index-dir = (dv-index-dir dv)
             for index-buf = (alist-get index-dir (dv-roots dv) nil nil #'equal)
             thereis (and (not (get-buffer-window index-buf))
                          (eq (dv-quit-window-fn dv) #'ignore)
                          (if fullscreen (dv-layout dv) t)
                          (prog1 (switch-to-buffer index-buf)
                            (dirvish-reclaim)
                            (dirvish-find-entry-ad file))))))

;;;; Core

(defun dirvish-curr (&optional frame)
  "Get current Dirvish session in FRAME (defaults to selected)."
  (or (dirvish-prop :dv) (frame-parameter frame 'dirvish--curr)))

(defun dirvish--util-buffer (&optional type dv no-create)
  "Return session DV's utility buffer of TYPE (defaults to `temp').
If NO-CREATE is non-nil, do not create the buffer."
  (let* ((id (if dv (format "-%s*" (dv-name dv)) "*"))
         (name (format " *Dirvish-%s%s" (or type "temp") id)))
    (if no-create (get-buffer name) (get-buffer-create name))))

(cl-defmacro dirvish-define-attribute (name docstring (&key if width) &rest body)
  "Define a Dirvish attribute NAME.
An attribute contains a pair of predicate/rendering functions
that are being called on `post-command-hook'.  The predicate fn
IF takes current DV as argument and executed once.  When it
evaluates to t, the rendering fn runs BODY for every line with
following arguments:

- `f-beg'   from `dired-move-to-filename'
- `f-end'   from `dired-move-to-end-of-filename'
- `f-str'   from (`buffer-substring' F-BEG F-END)
- `f-wid'   from `(`string-width' F-STR)'
- `f-dir'   from `dired-current-directory'
- `f-name'  from `dired-get-filename'
- `f-attrs' from `file-attributes'
- `f-type'  from `file-directory-p' along with `file-symlink-p'
- `l-beg'   from `line-beginning-position'
- `l-end'   from `line-end-position'
- `remain'  remained space (width) of current line
- `hl-face' a face that is only passed in on current line

DOCSTRING is the docstring for the attribute.  WIDTH designates
the length of the attribute."
  (declare (indent defun) (doc-string 2))
  (let* ((ov (intern (format "dirvish-%s-ov" name)))
         (pred (intern (format "dirvish-attribute-%s-pred" name)))
         (render (intern (format "dirvish-attribute-%s-rd" name)))
         (args '(f-beg f-end f-str f-wid f-dir f-name f-attrs f-type l-beg l-end remain hl-face))
         (pred-body (if (> (length if) 0) if t)))
    `(progn
       (add-to-list
        'dirvish--available-attrs
        (cons ',name '(:doc ,docstring :width ,width :overlay ,ov :if ,pred :fn ,render)))
       (cl-loop
        with doc-head = "All available `dirvish-attributes'.
This is a internal variable and should *NOT* be set manually."
        with attr-docs = ""
        with attrs = (seq-remove (lambda (i) (memq (car i) dirvish--builtin-attrs))
                                 dirvish--available-attrs)
        for (a-name . a-plist) in attrs
        do (setq attr-docs (format "%s\n\n`%s': %s" attr-docs a-name
                                   (plist-get a-plist :doc)))
        finally do (put 'dirvish--available-attrs 'variable-documentation
                        (format "%s%s" doc-head attr-docs)))
       (defun ,pred (dv) (ignore dv) ,pred-body)
       (defun ,render ,args
         (ignore ,@args)
         (let ((ov ,@body)) (and ov (overlay-put ov ',ov t)))))))

(defmacro dirvish-attribute-cache (file attribute &rest body)
  "Get FILE's ATTRIBUTE from `dirvish--attrs-hash'.
When the attribute does not exist, set it with BODY."
  (declare (indent defun))
  `(let* ((hash (gethash ,file dirvish--attrs-hash))
          (cached (plist-get hash ,attribute))
          (attr (or cached ,@body)))
     (unless cached
       (puthash ,file (append hash (list ,attribute attr)) dirvish--attrs-hash))
     attr))

(cl-defmacro dirvish-define-preview (name &optional arglist docstring &rest body)
  "Define a Dirvish preview dispatcher NAME.
A dirvish preview dispatcher is a function consumed by
 `dirvish-preview-dispatch' which takes `file' (filename under
 the cursor) and `preview-window' as ARGLIST.  DOCSTRING and BODY
 is the docstring and body for this function."
  (declare (indent defun) (doc-string 3))
  (let* ((dp-name (intern (format "dirvish-%s-preview-dp" name)))
         (default-arglist '(file ext preview-window dv))
         (ignore-list (cl-set-difference default-arglist arglist)))
    `(progn (defun ,dp-name ,default-arglist ,docstring (ignore ,@ignore-list) ,@body))))

(cl-defmacro dirvish-define-mode-line (name &optional docstring &rest body)
  "Define a mode line segment NAME with BODY and DOCSTRING."
  (declare (indent defun) (doc-string 2))
  (let ((ml-name (intern (format "dirvish-%s-ml" name))))
    `(progn
       (add-to-list
        'dirvish--available-mode-line-segments (cons ',name ,docstring))
       (cl-loop
        with doc-head = "All available segments for `dirvish-mode/header-line-format'.
This is a internal variable and should *NOT* be set manually."
        with attr-docs = ""
        for (seg-name . doc) in dirvish--available-mode-line-segments
        do (setq attr-docs (format "%s\n\n`%s': %s" attr-docs seg-name doc))
        finally do (put 'dirvish--available-mode-line-segments 'variable-documentation
                        (format "%s%s" doc-head attr-docs)))
       (defun ,ml-name (dv) ,docstring (ignore dv) ,@body))))

(defun dirvish-get-all (slot &optional all-frame flatten)
  "Gather slot value SLOT of all Dirvish in `dirvish--hash'.
If ALL-FRAME is non-nil, collect for all frames.
If FLATTEN is non-nil, collect them as a flattened list."
  (cl-loop
   with dv-slot = (intern (format "dv-%s" slot))
   with h-vals = (hash-table-values dirvish--hash)
   with s-vals = (mapcar dv-slot h-vals)
   for h-val in h-vals
   when (or all-frame (eq (plist-get (dv-scopes h-val) :frame)
                          (selected-frame)))
   for s-val in s-vals
   if flatten append (delete-dups (flatten-tree s-val))
   else collect s-val))

(cl-defstruct (dirvish (:conc-name dv-))
  "Define dirvish data type."
  (path nil :documentation "is the initial directory.")
  (layout () :documentation "Todo.")
  (last-fs-layout dirvish-default-layout :documentation "Todo.")
  (attributes (purecopy dirvish-attributes) :documentation "is the actual `dirvish-attributes'.")
  (attribute-fns () :documentation "are render functions expanded from ATTRIBUTES.")
  (preview-dispatchers (purecopy dirvish-preview-dispatchers)
                       :documentation "are actual `dirvish-preview-dispatchers'.")
  (preview-fns () :documentation "are preview functions expanded from PREVIEW-DISPATCHERS.")
  (ls-switches dired-listing-switches :documentation "is the listing switches.")
  (header-line-format dirvish-header-line-format :documentation "is the actual header line format.")
  (mode-line-format dirvish-mode-line-format :documentation "is the actual mode line format.")
  (root-window-fn (lambda (_dv) (frame-selected-window))
                  :documentation "is the function to create the ROOT-WINDOW.")
  (root-window nil :documentation "is the main window created by ROOT-WINDOW-FN.")
  (on-file-open #'dirvish-on-file-open :documentation "Function to run before opening a file.")
  (quit-window-fn #'ignore :documentation "is the function being called on `quit-window'.")
  (scopes () :documentation "are the \"environments\" such as init frame of this session.")
  (preview-buffers () :documentation "holds all file preview buffers in this session.")
  (preview-window nil :documentation "is the window to display preview buffer.")
  (name (cl-gensym) :documentation "is an unique symbol for every session.")
  (window-conf (current-window-configuration) :documentation "is the saved window configuration.")
  (roots () :documentation "is a alist of (INDEX-DIR . CORRESPONDING-BUFFER).")
  (parents () :documentation "is like ROOT, but for parent windows.")
  (index-dir "" :documentation "is the `default-directory' in ROOT-WINDOW."))

(defmacro dirvish-new (kill-old &rest args)
  "Create a new dirvish struct and put it into `dirvish--hash'.
ARGS is a list of keyword arguments followed by an optional BODY.
The keyword arguments set the fields of the dirvish struct.
If BODY is given, it is executed to set the window configuration
for the dirvish.
When KILL-OLD is non-nil, avoid overlapping sessions.
Save point, and current buffer before executing BODY, and then
restore them after."
  (declare (indent defun))
  (let ((keywords))
    (while (keywordp (car args))
      (dotimes (_ 2) (push (pop args) keywords)))
    (setq keywords (reverse keywords))
    `(let ((old (dirvish-curr))
           (new (make-dirvish ,@keywords)))
       (puthash (dv-name new) new dirvish--hash)
       (dirvish--refresh-slots new)
       (dirvish--create-root-window new)
       (setf (dv-scopes new)
             (cl-loop
              with res-plist = `(:dv ,new :point ,(point))
              for (key value) on dirvish-scopes by 'cddr do
              (setq res-plist (append res-plist (list key (funcall value))))
              finally return res-plist))
       (when (and old ,kill-old (eq (dv-root-window old) (dv-root-window new)))
         (dirvish-kill old))
       (set-frame-parameter nil 'dirvish--curr new)
       (when-let ((path (dv-path new)))
         (dirvish-find-entry-ad (expand-file-name (file-name-directory path))))
       (run-hooks 'dirvish-activation-hook)
       ,(when args `(save-excursion ,@args)) ; Body form given
       new)))

(defun dirvish-reclaim (&optional frame-or-window)
  "Reclaim current Dirvish in FRAME-OR-WINDOW."
  (let ((old (dirvish-curr))
        (new (dirvish-prop :dv))
        (bufname (buffer-name))
        (fd-regex "\\(^*Find*\\)\\|\\(^FD####\\)"))
    (when (and (not new) (string-match fd-regex bufname))
      (setq new (or old (dirvish-new nil :layout dirvish-default-layout))))
    (cond ((or (active-minibuffer-window)
               (and old (eq (frame-selected-window)
                            (dv-preview-window old)))))
          (new
           (setq tab-bar-new-tab-choice "*scratch*")
           (when (dv-layout new)
             (setq other-window-scroll-buffer
                   (window-buffer (dv-preview-window new))))
           (setf (dv-root-window new) (frame-selected-window frame-or-window))
           (set-frame-parameter nil 'dirvish--curr new))
          (t
           (setq tab-bar-new-tab-choice dirvish--saved-new-tab-choice)
           (setq other-window-scroll-buffer nil)
           (set-frame-parameter nil 'dirvish--curr nil)))))

(defun dirvish-kill (dv &optional keep-current)
  "Kill a dirvish instance DV and remove it from `dirvish--hash'.
If KEEP-CURRENT, do not kill the current directory buffer."
  (when (dv-layout dv)
    (set-window-configuration (dv-window-conf dv))
    (goto-char (plist-get (dv-scopes dv) :point))
    (remhash (dv-name dv) dirvish--hash))
  (if keep-current
      (progn (mapc #'dirvish--kill-buffer (seq-remove (lambda (i) (eq i (current-buffer)))
                                           (mapcar #'cdr (dv-roots dv))))
             (setf (dv-roots dv) (list (cons (dv-index-dir dv) (current-buffer))))
             (unless (dv-layout dv) (let (quit-window-hook) (quit-window))))
    (mapc #'dirvish--kill-buffer (mapcar #'cdr (dv-roots dv)))
    (remhash (dv-name dv) dirvish--hash))
  (dolist (type '(preview header footer))
    (dirvish--kill-buffer (dirvish--util-buffer type dv)))
  (mapc #'dirvish--kill-buffer (dv-preview-buffers dv))
  (mapc #'dirvish--kill-buffer (mapcar #'cdr (dv-parents dv)))
  (funcall (dv-quit-window-fn dv) dv)
  (dirvish-reclaim)
  (run-hooks 'dirvish-deactivation-hook))

(defun dirvish-on-file-open (dv)
  "Called before opening a file in Dirvish session DV."
  (dirvish-kill dv dirvish-reuse-session))

(defun dirvish--create-root-window (dv)
  "Create root window of DV."
  (let ((win (funcall (dv-root-window-fn dv) dv)))
    (setf (dv-root-window dv) win)
    win))

(defun dirvish--refresh-slots (dv)
  "Update dynamic slot values of DV."
  (cl-loop with dv-attrs = (dv-attributes dv)
           with reorder = dirvish--builtin-attrs
           for (lib . attrs) in dirvish-attrs-library do
           (when-let ((match (cl-intersection attrs dv-attrs)))
             (unless (featurep lib) (require lib))
             (setq reorder (append reorder match)))
           finally do
           (setf (dv-attribute-fns dv)
                 (cl-loop
                  for name in reorder
                  for attr = (cdr (assoc name dirvish--available-attrs)) collect
                  (cl-destructuring-bind
                      (&key overlay if fn width &allow-other-keys)
                      attr (list overlay if fn width)))))
  (setf (dv-preview-fns dv)
        (cl-loop for dp in (append '(tramp disable) (dv-preview-dispatchers dv) '(default))
                 collect (intern (format "dirvish-%s-preview-dp" dp)))))

(defun dirvish--render-attributes-1 (height width subtrees pos tramp fns)
  "HEIGHT WIDTH SUBTREES POS TRAMP FNS."
  (forward-line (- 0 height))
  (cl-dotimes (_ (* 2 height))
    (when (eobp) (cl-return))
    (let ((f-beg (dired-move-to-filename))
          (f-end (dired-move-to-end-of-filename t))
          (l-beg (line-beginning-position))
          (l-end (line-end-position))
          (width (- width (if subtrees (dirvish-subtree--prefix-length) 0)))
          f-str f-wid f-dir f-name f-attrs f-type hl-face)
      (setq hl-face (and (eq (or f-beg l-beg) pos) 'dirvish-hl-line))
      (when f-beg
        (setq f-str (buffer-substring f-beg f-end))
        (setq f-wid (string-width f-str))
        (setq f-dir (dired-current-directory))
        (setq f-name (file-local-name (expand-file-name f-str f-dir)))
        (setq f-attrs (dirvish-attribute-cache f-name :builtin
                        (unless tramp (file-attributes f-name))))
        (setq f-type (dirvish-attribute-cache f-name :type
                       (let ((ch (progn (back-to-indentation) (char-after))))
                         `(,(if (eq ch 100) 'dir 'file) . nil))))
        (unless (get-text-property f-beg 'mouse-face)
          (dired-insert-set-properties l-beg l-end)))
      (dolist (fn (if f-beg fns '(dirvish-attribute-hl-line-rd)))
        (funcall fn f-beg f-end f-str f-wid f-dir f-name
                 f-attrs f-type l-beg l-end width hl-face)))
    (forward-line 1)))

(defun dirvish--render-attributes (dv)
  "Render attributes in Dirvish session DV's body."
  (cl-loop with tramp = (dirvish-prop :tramp)
           with subtrees = (bound-and-true-p dirvish-subtree--overlays)
           with height = (frame-height) ; use `window-height' here breaks `dirvish-narrow'
           with width = (window-width) with fns = ()
           for (ov pred fn wd) in (dv-attribute-fns dv)
           do (remove-overlays (point-min) (point-max) ov t)
           when (funcall pred dv) do
           (progn (setq width (- width (or (eval wd) 0))) (push fn fns))
           finally do (with-silent-modifications
                        (save-excursion (dirvish--render-attributes-1
                                         height width subtrees (point) tramp fns)))))

;;;; Advices

(defun dirvish-dired-ad (dirname &optional switches)
  "Override `dired' command.
DIRNAME and SWITCHES are same with command `dired'."
  (dirvish-new t :path dirname :ls-switches switches))

(defun dirvish-dired-other-window-ad (dirname &optional switches)
  "Override `dired-other-window' command.
DIRNAME and SWITCHES are same with command `dired'."
  (when-let ((dv (dirvish-curr)))
    (when (dv-layout dv) (dirvish-kill dv)))
  (switch-to-buffer-other-window (dirvish--util-buffer))
  (dirvish-new t :path dirname :ls-switches switches))

(defun dirvish-dired-other-tab-ad (dirname &optional switches)
  "Override `dired-other-tab' command.
DIRNAME and SWITCHES are the same args in `dired'."
  (switch-to-buffer-other-tab "*scratch*")
  (with-current-buffer "*scratch*" ; why do we need this?
    (dirvish-new t :path dirname :ls-switches switches :layout dirvish-default-layout)))

(defun dirvish-dired-other-frame-ad (dirname &optional switches)
  "Override `dired-other-frame' command.
DIRNAME and SWITCHES are the same args in `dired'."
  (let (after-focus-change-function)
    (switch-to-buffer-other-frame (dirvish--util-buffer))
    (dirvish-new t :path dirname :ls-switches switches :layout dirvish-default-layout)))

(defun dirvish-dired-jump-ad (&optional other-window file-name)
  "Override `dired-jump' command.
OTHER-WINDOW and FILE-NAME are the same args in `dired-jump'."
  (let ((file-name (or file-name default-directory)))
    (and other-window (switch-to-buffer-other-window (dirvish--util-buffer)))
    (if (dirvish-curr)
        (dirvish-find-entry-ad file-name)
      (dirvish--reuse-session file-name)
      (unless (dirvish-prop :dv)
        (dirvish-new t :path file-name)))))

(defun dirvish-find-entry-ad (&optional entry)
  "Find file in dirvish buffer.
ENTRY can be a filename or a string with format of
`dirvish-fd-bufname' used to query or create a `fd' result
buffer, it defaults to filename under the cursor when it is nil."
  (let* ((entry (or entry (dired-get-filename nil t)))
         (buffer (dirvish--find-entry (dirvish-curr) entry)))
    (if buffer
        (dirvish-with-no-dedication
         (switch-to-buffer buffer)
         (when-let ((dv (dirvish-curr))) (dirvish--build dv)))
      (find-file entry))))

(defun dirvish-up-directory-ad (&optional other-window)
  "Override `dired-up-directory' command.
If OTHER-WINDOW, display the parent directory in other window."
  (let* ((current (expand-file-name default-directory))
         (parent (dirvish--get-parent-path current)))
    (if (string= parent current)
        (user-error "Dirvish: you're in root directory")
      (if other-window
          (progn
            (switch-to-buffer-other-window (dirvish--util-buffer))
            (dirvish-new nil :path parent))
        (dirvish-find-entry-ad parent)))))

(defun dirvish-find-file-other-win-ad (&rest _)
  "Override `dired-find-file-other-window' command."
  (let ((dv (dirvish-curr))
        (file (dired-get-file-for-visit)))
    (if (dv-layout dv)
        (if (file-directory-p file)
            (dired-other-frame file)
          (dirvish-kill (dirvish-prop :dv))
          (switch-to-buffer-other-window (current-buffer))
          (find-file file))
      (if (file-directory-p file)
          (dired-other-window file)
        (other-window 1)
        (find-file file)))))

(defun dirvish-find-dired-sentinel-ad (proc _)
  "Advice function for process PROC of `find-dired-sentinel'."
  (let ((dv (dirvish-curr))
        (bufname (buffer-name))
        buffer-read-only)
    (setf (dv-index-dir dv) bufname)
    (unless (alist-get bufname (dv-roots dv) nil nil #'equal)
      (push (cons bufname (current-buffer)) (dv-roots dv)))
    (with-current-buffer (process-buffer proc)
      (setq-local dirvish--attrs-hash (make-hash-table :test #'equal))
      (dirvish-prop :child (dired-get-filename nil t))
      (dirvish-prop :dv dv)
      (dirvish-prop :fd-dir bufname)
      (delete-matching-lines "find finished at.*\\|^ +$")
      (dirvish--hide-dired-header))
    (dirvish--build dv)))

(defun dirvish-dwim-target-next-ad (&optional all-frames)
  "Replacement for `dired-dwim-target-next'.
If ALL-FRAMES, search target directories in all frames."
  (delete (dired-current-directory) (dirvish-get-all 'index-dir all-frames t)))

(defun dirvish-wdired-enter-ad (&rest _)
  "Advisor function for `wdired-change-to-wdired-mode'."
  (dired-move-to-end-of-filename t)
  (setq-local cursor-type '(bar 4))
  (dolist (ov (mapcar #'car (dv-attribute-fns (dirvish-curr))))
    (remove-overlays (point-min) (point-max) ov t))
  (remove-hook 'post-command-hook #'dirvish-update-body-h t))

(defun dirvish-wdired-exit-ad (&rest _)
  "Advise function for exiting `wdired-mode'."
  (dirvish--hide-dired-header (dirvish-setup)))

(defun dirvish-find-file-ad (fn filename &optional wildcard)
  "Advice for FN `find-file' and `find-file-other-window'.
FILENAME and WILDCARD are their args."
  (let* ((ext (downcase (or (file-name-extension filename) "")))
         (file (expand-file-name filename))
         (process-connection-type nil)
         (ex-cmd (cl-loop
                  for (exts . (cmd . args)) in dirvish-open-with-programs
                  thereis (and (not (dirvish-prop :tramp))
                               (executable-find cmd)
                               (member ext exts)
                               (append (list cmd) args)))))
    (cond (ex-cmd
           (and (bound-and-true-p recentf-mode) (add-to-list 'recentf-list file))
           (apply #'start-process "" nil "nohup"
                  (cl-substitute file "%f" ex-cmd :test 'string=)))
          (t (when-let ((dv (dirvish-prop :dv))) (funcall (dv-on-file-open dv) dv))
             (funcall fn file wildcard)))))

(defun dirvish-ignore-ad (fn &rest args)
  "Only apply FN with ARGS outside of Dirvish."
  (when (or (not (dirvish-curr)) (derived-mode-p 'wdired-mode))
    (apply fn args)))

(defun dirvish-deactivate-tab-h (tab _only-tab)
  "Deactivate all Dirvish sessions in TAB."
  (dolist (scope (dirvish-get-all 'scopes))
    (when (eq (plist-get scope :tab) (tab-bar--tab-index tab))
      (dirvish-kill (plist-get scope :dv)))))

(defun dirvish-deactivate-frame-h (frame)
  "Deactivate all dvs in FRAME."
  (dolist (scope (dirvish-get-all 'scopes t))
    (when (eq (plist-get scope :frame) frame)
      (dirvish-kill (plist-get scope :dv)))))

(defun dirvish-deactivate-minibuffer-h ()
  "Deactivate Dirvish session in minibuffer."
  (dolist (scope (dirvish-get-all 'scopes t))
    (when (eq (plist-get scope :mini) (active-minibuffer-window))
      (dirvish-kill (plist-get scope :dv)))))

;;;; Preview

(defun dirvish--preview-image-size (window &optional height)
  "Get corresponding image width or HEIGHT in WINDOW."
  (floor (* dirvish--preview-img-scale
            (funcall (if height #'window-pixel-height #'window-pixel-width) window))))

(defun dirvish--preview-insert-image (image dv)
  "Insert IMAGE at preview window of DV."
  (insert " ")
  (add-text-properties 1 2 `(display ,image rear-nonsticky t keymap ,image-map))
  (pcase-let ((`(,iw . ,ih) (image-size image)))
    (let* ((p-window (dv-preview-window dv))
           (w-offset (max (round (/ (- (window-width p-window) iw) 2)) 0))
           (h-offset (max (round (/ (- (window-height p-window) ih) 2)) 0)))
      (goto-char 1)
      (insert (make-string h-offset ?\n) (make-string w-offset ?\s)))))

(defun dirvish--preview-inhibit-long-line (file)
  "Preview FILE unless it contains long lines."
  (let* ((enable-local-variables nil)
         (vc-follow-symlinks t)
         (buf (find-file-noselect file t)))
    (with-current-buffer buf
      (if (funcall so-long-predicate)
          (progn
            (kill-buffer buf)
            `(info . ,(format "File %s contains very long lines, preview skipped." file)))
        `(buffer . ,buf)))))

(defun dirvish--preview-clean-cache-images (fileset)
  "Clean image cache for FILESET."
  (clear-image-cache)
  (let ((win (dv-preview-window (dirvish-curr))) size)
    (when (window-live-p win)
      (setq size (dirvish--preview-image-size win))
      (dolist (file fileset)
        (mapc #'delete-file (file-expand-wildcards
                             (dirvish--cache-path-for-file file size ".*" t) t))))))

(defun dirvish--preview-fill-string-sentinel (proc _exitcode)
  "A sentinel for dirvish preview process.
When PROC finishes, fill preview buffer with process result."
  (when-let ((dv (dirvish-curr)))
    (with-current-buffer (dirvish--util-buffer 'preview dv)
      (erase-buffer) (remove-overlays)
      (let* ((proc-buf (process-buffer proc))
             (result-str (with-current-buffer proc-buf (buffer-string)))
             (p-min (point-min)))
        (with-current-buffer proc-buf (erase-buffer))
        (insert result-str)
        (dirvish-apply-ansicolor-h nil p-min)))))

(defun dirvish--preview-img-cache-sentinel (proc _exitcode)
  "Sentinel for image cache process PROC."
  (when-let* ((dv (dirvish-curr))
              (path (dirvish-prop :child)))
    (and (equal path (process-get proc 'path))
         (dirvish-debounce layout (dirvish-preview-update dv)))))

(dirvish-define-preview tramp (file _ dv)
  "Preview files with `ls' or `head' for tramp files."
  (when-let ((tramp-info (dirvish-prop :tramp)))
    (if (dirvish--host-in-whitelist-p tramp-info)
        (let ((process-connection-type nil)
              (localname (file-remote-p file 'localname))
              (buf (dirvish--util-buffer 'preview dv)) proc)
          (when-let ((proc (get-buffer-process buf))) (delete-process proc))
          (setq proc (tramp-handle-shell-command
                      (format dirvish--tramp-preview-cmd localname localname) buf))
          (set-process-sentinel
           proc (lambda (proc _sig)
                  (when (memq (process-status proc) '(exit signal))
                    (shell-command-set-point-after-cmd (process-buffer proc)))))
          (set-process-filter
           proc (lambda (proc str) (with-current-buffer (process-buffer proc) (insert str))))
          `(buffer . ,buf))
      '(info . "File preview is not supported in current TRAMP connection"))))

(dirvish-define-preview disable (file)
  "Disable preview in some cases."
  (when (or (not (file-exists-p file))
            (not (file-readable-p file))
            (member (downcase (or (file-name-extension file) "")) dirvish-preview-disabled-exts))
    `(info . ,(format "Preview for %s has been disabled" file))))

(dirvish-define-preview gif (file ext)
  "Display an animated image FILE."
  (when (equal ext "gif")
    (let ((gif-buf (find-file-noselect file t))
          (callback (lambda (buf)
                      (when (buffer-live-p buf)
                        (with-current-buffer buf
                          (image-animate (get-char-property 1 'display)))))))
      (run-with-idle-timer 1 nil callback gif-buf)
      `(buffer . ,gif-buf))))

(dirvish-define-preview audio (file ext)
  "Use output of `mediainfo' command for FILE as preview."
  (when (member ext dirvish-audio-exts) `(shell . ("mediainfo" ,file))))

(dirvish-define-preview image (file ext preview-window)
  "Display a image FILE in PREVIEW-WINDOW."
  (when (member ext dirvish-image-exts)
    (let* ((width (dirvish--preview-image-size preview-window))
           (height (dirvish--preview-image-size preview-window 'height))
           (cache (dirvish--cache-path-for-file file width ".jpg")))
      (cond ((file-exists-p cache)
             `(image . ,(create-image cache nil nil :max-width width :max-height height)))
            ((or (> (nth 7 (file-attributes file)) dirvish--img-cache-threshold)
                 (member ext dirvish--img-always-cache-exts))
             `(image-cache . ("convert" ,file "-define" "jpeg:extent=300kb" "-resize"
                              ,(number-to-string width) ,cache)))
            (t `(image . ,(create-image file nil nil :max-width width :max-height height)))))))

(dirvish-define-preview video (file ext preview-window)
  "Display a video thumbnail for FILE in PREVIEW-WINDOW."
  (when (member ext dirvish-video-exts)
    (let* ((width (dirvish--preview-image-size preview-window))
           (height (dirvish--preview-image-size preview-window 'height))
           (cache (dirvish--cache-path-for-file file width ".jpg")))
      (if (file-exists-p cache)
          `(image . ,(create-image cache nil nil :max-width width :max-height height))
        `(image-cache . ("ffmpegthumbnailer" "-i" ,file "-o" ,cache "-s"
                         ,(number-to-string width)
                         ,(if dirvish--cache-embedded-video-thumb "-m" "")))))))

(dirvish-define-preview epub (file preview-window)
  "Display a epub thumbnail for FILE in PREVIEW-WINDOW."
  (when (equal ext "epub")
    (let* ((width (dirvish--preview-image-size preview-window))
           (height (dirvish--preview-image-size preview-window 'height))
           (cache (dirvish--cache-path-for-file file width ".jpg")))
      (if (file-exists-p cache)
          `(image . ,(create-image cache nil nil :max-width width :max-height height))
        `(image-cache . ("epub-thumbnailer" ,file ,cache ,(number-to-string width)))))))

(dirvish-define-preview pdf (file ext)
  "Open FILE with `find-file-noselect'."
  (when (equal ext "pdf")
    (if (featurep 'pdf-tools) `(buffer . ,(find-file-noselect file t nil))
      '(info . "Emacs package 'pdf-tools' is required to preview pdf documents"))))

(dirvish-define-preview archive (file ext)
  "Display output of corresponding unarchive commands for FILE."
  (cond ((equal ext "zip") `(shell . ("zipinfo" ,file)))
        ((member ext '("tar" "zst")) `(shell . ("tar" "-tvf" ,file)))))

(dirvish-define-preview default (file)
  "Default preview dispatcher for FILE."
  (let ((threshold (or large-file-warning-threshold 10000000))
        (filesize (file-attribute-size (file-attributes file)))
        (enable-local-variables nil))
    (cond ((file-directory-p file) ; in case user did not specify a directory dispatcher
           `(buffer . ,(dired-noselect file)))
          ((> filesize threshold) ; do not preview too large files
           `(info . ,(format "File %s is too big for literal preview." file)))
          (t (dirvish--preview-inhibit-long-line file)))))

(defun dirvish-preview-dispatch (preview-type payload dv)
  "Execute dispatcher's PAYLOAD according to PREVIEW-TYPE.
This function apply the payloads provided by the first
matched preview dispatcher to the preview buffer, and finally
return the buffer.

PREVIEW-TYPE can be one of following values:

- `info', meaning PAYLOAD is a string.
- `buffer', meaning PAYLOAD is a buffer.
- `image', meaning PAYLOAD is a image.
- `image-cache', meaning PAYLOAD is a (IMAGE-CMD . ARGS) cons.
- `shell', meaning PAYLOAD is a (TEXT-CMD . ARGS) cons.

According to the PAYLOAD, one of these action is applied:

- A string/image PAYLOAD is inserted to the default preview buffer.
- A buffer PAYLOAD is used as preview buffer directly.
- A subprocess for IMAGE/TEXT-CMD is issued.  When the subprocess
finishes, the content in preview buffer is filled with the result
string of TEXT-CMD or the generated cache image of IMAGE-CMD."
  (let ((buf (dirvish--util-buffer 'preview dv))
        (cmd (car-safe payload))
        (args (cdr-safe payload))
        (path (dirvish-prop :child))
        (process-connection-type nil))
    (when (and (memq preview-type '(shell image-cache))
               (not (executable-find cmd)))
      (setq preview-type 'info
            payload (format "Install `%s' to preview this file." cmd)))
    (with-current-buffer buf
      (erase-buffer) (remove-overlays)
      (cl-case preview-type
        ('info (insert payload))
        ('buffer (setq buf payload))
        ('image (dirvish--preview-insert-image payload dv))
        ('image-cache
         (let* ((buf (dirvish--util-buffer "img-cache"))
                (name (format "%s-%s-img-cache" path
                              (window-width (dv-preview-window dv)))))
           (unless (get-process name)
             (setq dirvish--cache-pool
                   (delete (assoc name dirvish--cache-pool) dirvish--cache-pool))
             (let ((proc (apply #'start-process name buf cmd args)))
               (process-put proc 'path path)
               (set-process-sentinel proc #'dirvish--preview-img-cache-sentinel))))
         (insert " [Dirvish] Generating image cache..."))
        ('shell
         (let* ((res-buf (dirvish--util-buffer "shell-output"))
                (proc (apply #'start-process "dirvish-preview-process" res-buf cmd args)))
           (set-process-sentinel proc 'dirvish--preview-fill-string-sentinel))))
      buf)))

(defun dirvish-preview-update (&optional dv)
  "Update preview content of DV."
  (when-let* ((dv (or dv (dirvish-curr)))
              (window (dv-preview-window dv))
              (index (dirvish-prop :child)))
    (when (window-live-p window)
      (let* ((orig-buffer-list (buffer-list))
             (ext (downcase (or (file-name-extension index) "")))
             (buffer (cl-loop for dp-fn in (dv-preview-fns dv)
                              for (type . payload) = (funcall dp-fn index ext window dv)
                              thereis (and type (dirvish-preview-dispatch
                                                 type payload dv)))))
        (setq other-window-scroll-buffer buffer)
        (set-window-buffer window buffer)
        (unless (memq buffer orig-buffer-list)
          (push buffer (dv-preview-buffers dv)))))))

;;;; Builder

(dirvish-define-attribute hl-line "Highlight current line." ()
  (when hl-face
    (let ((ov (make-overlay l-beg (1+ l-end)))) (overlay-put ov 'face hl-face) ov)))

(dirvish-define-attribute symlink-target "Hide symlink target."
  (:if (and dired-hide-details-mode
            (default-value 'dired-hide-details-hide-symlink-targets)))
  (when (< (+ f-end 4) l-end)
    (let ((ov (make-overlay f-end l-end))) (overlay-put ov 'invisible t) ov)))

;; Thanks to `doom-modeline'.
(defun dirvish--bar-image (fullscreenp header)
  "Create a bar image with height of `dirvish-mode-line-height'.
If FULLSCREENP, use the `cdr' of the value as height, otherwise
use `car'.  If HEADER, use `dirvish-header-line-height' instead."
  (when (and (display-graphic-p) (image-type-available-p 'pbm))
    (let* ((height-vals
            (if header dirvish-header-line-height dirvish-mode-line-height))
           (height (if fullscreenp (cdr height-vals) (car height-vals))))
      (propertize
       " " 'display
       (ignore-errors
         (create-image
          (concat (format "P1\n%i %i\n" 2 height)
                  (make-string (* 2 height) ?1) "\n")
          'pbm t :foreground "None" :ascent 'center))))))

(cl-defgeneric dirvish-search-switches-ml (_dv)
  "Return a string showing current search options and pattern.
The string is placed at header after a search is issued.  The
default implementation is `find-args' with simple formatting."
  (format " %s [%s] " (propertize "Find args:" 'face 'dired-header)
          (propertize find-args 'face 'font-lock-string-face)))

(dirvish-define-mode-line path
  "Path of file under the cursor."
  (when-let ((index (or (dirvish-prop :child) (dired-get-filename nil t))))
    (let* ((localname (file-local-name index))
           (host (file-remote-p index 'host))
           (user (file-remote-p index 'user))
           (dirname (file-name-directory localname))
           (base (file-name-nondirectory index))
           dir-tail tail)
      (if host
          (setq dir-tail (replace-regexp-in-string "\\/$\\|^\\/" "" dirname))
        (setq dir-tail (replace-regexp-in-string dirvish--dir-tail-regex "" dirname)))
      (setq tail (if (equal dir-tail "") "" (concat dir-tail " ")))
      (format " %s%s%s%s "
              (propertize
               (cond ((and host user) (concat user "@" host ": "))
                     (host (concat host ": "))
                     (t ""))
               'face 'font-lock-builtin-face)
              (propertize (cond (host "")
                                ((string-prefix-p (file-name-as-directory (getenv "HOME")) dirname) "~ ")
                                (t ": "))
                          'face 'dired-header)
              (propertize tail 'face 'dired-mark)
              (propertize base 'face 'dired-header)))))

(dirvish-define-mode-line sort
  "Current sort criteria."
  (let* ((switches (split-string dired-actual-switches))
         (crit (cond (dired-sort-inhibit "DISABLED")
                     ((member "--sort=none" switches) "none")
                     ((member "--sort=time" switches) "time")
                     ((member "--sort=version" switches) "version")
                     ((member "--sort=size" switches) "size")
                     ((member "--sort=extension" switches) "extension")
                     ((member "--sort=width" switches) "width")
                     (t "name")))
         (time (cond ((member "--time=use" switches) "use")
                     ((member "--time=ctime" switches) "ctime")
                     ((member "--time=birth" switches) "birth")
                     (t "mtime")))
         (rev (if (member "--reverse" switches) "↓" "↑")))
    (format " %s %s|%s "
            (propertize rev 'face 'font-lock-doc-markup-face)
            (propertize crit 'face 'font-lock-type-face)
            (propertize time 'face 'font-lock-doc-face))))

(dirvish-define-mode-line omit
  "A `dired-omit-mode' indicator."
  (and (bound-and-true-p dired-omit-mode) (propertize "Omit" 'face 'font-lock-negation-char-face)))

(dirvish-define-mode-line symlink
  "Show the truename of symlink file under the cursor."
  (when-let* ((name (or (dirvish-prop :child) (dired-get-filename nil t)))
              (f-name (file-local-name name))
              (truename (cdr (dirvish-attribute-cache f-name :type))))
    (format " %s %s "
            (propertize "→" 'face 'font-lock-comment-delimiter-face)
            (propertize truename 'face 'dired-symlink))))

(dirvish-define-mode-line index
  "Current file's index and total files count."
  (let ((cur-pos (- (line-number-at-pos (point)) 1))
        (fin-pos (number-to-string (- (line-number-at-pos (point-max)) 2))))
    (format " %d / %s " cur-pos (propertize fin-pos 'face 'bold))))

(dirvish-define-mode-line search-time
  "Timestamp of search finished."
  (unless (dirvish-prop :fd-time)
    (dirvish-prop :fd-time
      (format " %s %s  "
              (propertize "Finished at:" 'face 'font-lock-doc-face)
              (propertize (current-time-string) 'face 'success))))
  (when (dv-layout dv) (dirvish-prop :fd-time)))

(dirvish-define-mode-line pwd
  "Current working directory."
  (propertize (abbreviate-file-name default-directory) 'face 'dired-directory))

(defun dirvish-update-body-h ()
  "Update UI of current Dirvish."
  (when-let ((dv (dirvish-curr)))
    (cond ((eobp) (forward-line -1))
          ((bobp) (forward-line (if dirvish--dired-free-space 2 1))))
    (dired-move-to-filename)
    (dirvish--render-attributes dv)
    (when-let ((filename (dired-get-filename nil t)))
      (dirvish-prop :child filename)
      (let ((h-buf (dirvish--util-buffer 'header dv t))
            (f-buf (dirvish--util-buffer 'footer dv t))
            (this-cmd this-command))
        (dirvish-debounce layout
          (when (dv-layout dv)
            (when (and (not (eq dirvish-mode-line-position 'disable))
                       (buffer-live-p f-buf))
              (with-current-buffer f-buf (force-mode-line-update)))
            (when (and (not (eq dirvish-header-line-position 'disable))
                       (buffer-live-p h-buf))
              (with-current-buffer h-buf (force-mode-line-update)))
            (unless (memq this-cmd dirvish--no-update-preview-cmds)
              (dirvish-preview-update))))))))

(defun dirvish-quit-window-h ()
  "Hook function added to `quit-window' locally."
  (dirvish-kill (dirvish-prop :dv) dirvish-reuse-session)
  (switch-to-buffer (dirvish--util-buffer)))

(defun dirvish-kill-buffer-h ()
  "Hook function added to `kill-buffer' locally."
  (let ((dv (dirvish-prop :dv)))
    (setf (dv-roots dv) (cl-remove-if (lambda (i) (eq (cdr i) (current-buffer))) (dv-roots dv)))
    (unless (dv-roots dv)
      (remhash (dv-name dv) dirvish--hash)
      (dolist (type '(preview header footer))
        (dirvish--kill-buffer (dirvish--util-buffer type dv))))))

(defun dirvish-revert (&optional _arg _noconfirm)
  "Reread the Dirvish buffer.
Dirvish sets `revert-buffer-function' to this function."
  (cl-letf (((symbol-function 'dired-insert-set-properties) #'ignore))
    (dired-revert))
  (dirvish--hide-dired-header)
  (let ((vec (dirvish-prop :tramp)))
    (setq dirvish--attrs-hash (make-hash-table :test #'equal))
    (dirvish--print-directory vec (current-buffer) default-directory)
    (unless vec (dirvish--preview-clean-cache-images (dired-get-marked-files))))
  (run-hooks 'dirvish-after-revert-hook))

(defun dirvish-setup ()
  "Configurations for dirvish parent windows."
  (setq-local cursor-type nil)
  (when (boundp 'evil-normal-state-cursor)
    (setq-local evil-normal-state-cursor '(bar . 0)))
  (set-window-fringes nil 1 1)
  (when-let ((child (dirvish-prop :child))) (dired-goto-file child))
  (let* ((dv (dirvish-curr))
         (layout (dv-layout dv)))
    (cond ((functionp dirvish-hide-details)
           (funcall dirvish-hide-details dv))
          (dirvish-hide-details
           (let (dired-hide-details-mode-hook)
             (dired-hide-details-mode t))))
    (dirvish--render-attributes dv)
    (dirvish-prop :dv dv)
    (setq mode-line-format
          (cond ((or layout (eq dirvish-mode-line-position 'disable)) nil)
                (t (dv-mode-line-format dv))))
    (setq header-line-format
          (cond ((or layout (eq dirvish-header-line-position 'disable)) nil)
                ((dirvish-prop :fd-dir) dirvish--search-switches)
                (t (dv-header-line-format dv)))))
  (add-hook 'window-buffer-change-functions #'dirvish-reclaim nil t)
  (add-hook 'post-command-hook #'dirvish-update-body-h nil t)
  (add-hook 'quit-window-hook #'dirvish-quit-window-h nil t)
  (add-hook 'kill-buffer-hook #'dirvish-kill-buffer-h nil t)
  (run-hooks 'dirvish-mode-hook)
  (set-buffer-modified-p nil))

(defun dirvish--noselect (dir)
  "Return the Dirvish buffer at DIR, do not select it."
  (let* ((dir (file-name-as-directory (expand-file-name dir)))
         (dv (dirvish-new nil)))
    (setf (dv-index-dir dv) dir)
    (with-current-buffer (dirvish--find-entry dv dir)
      (dirvish--build dv)
      (current-buffer))))

(defun dirvish--find-entry (dv entry &optional parent)
  "Return the root or PARENT buffer in DV for ENTRY.
If the buffer is not available, create it with `dired-noselect'."
  (let ((pairs (if parent (dv-parents dv) (dv-roots dv)))
        (bname (buffer-file-name)) buffer)
    (cond ((equal entry "*Find*") (setq buffer (get-buffer-create "*Find*")))
          ((string-prefix-p "FD####" entry)
           (setq buffer (or (alist-get entry pairs nil nil #'equal)
                            (pcase-let ((`(,_ ,dir ,pattern ,_) (split-string entry "####")))
                              (dirvish-fd dir pattern)))))
          ((file-directory-p entry)
           (setq entry (file-name-as-directory (expand-file-name entry)))
           (setq buffer (alist-get entry pairs nil nil #'equal))
           (unless parent (setf (dv-index-dir dv) entry))
           (unless buffer
             (cl-letf (((symbol-function 'dired-insert-set-properties) #'ignore))
               (setq buffer (dired-noselect entry (dv-ls-switches dv))))
             (with-current-buffer buffer
               (dirvish-mode)
               (setq dirvish--attrs-hash (make-hash-table :test #'equal))
               (setq-local revert-buffer-function #'dirvish-revert)
               (setq-local dired-hide-details-hide-symlink-targets nil)
               (dirvish--hide-dired-header)
               (let* ((trampp (tramp-tramp-file-p entry))
                      (vec (and trampp (tramp-dissect-file-name entry))))
                 (dirvish-prop :tramp vec)
                 (dirvish-prop :child (or bname entry))
                 (unless trampp
                   (dirvish-prop :files (directory-files entry t nil t)))))
             (push (cons entry buffer) (if parent (dv-parents dv) (dv-roots dv))))))
    (prog1 buffer (and buffer (run-hook-with-args
                               'dirvish-find-entry-hook dv entry buffer)))))

(defun dirvish--autocache ()
  "Pop and run the cache tasks in `dirvish--cache-pool'."
  (when (and dirvish--cache-pool
             (< (length (process-list))
                (cdr dirvish-auto-cache-threshold)))
    (let (process-connection-type proc)
      (pcase-let* ((`(,procname . (,path ,_width ,cmd ,args))
                    (pop dirvish--cache-pool)))
        (when path
          (setq proc (apply #'start-process procname
                            (dirvish--util-buffer "img-cache") cmd args))
          (process-put proc 'path path)
          (set-process-sentinel proc #'dirvish--preview-img-cache-sentinel))))))

(defun dirvish--create-parent-windows (dv)
  "Create all dirvish parent windows for DV."
  (let* ((current (expand-file-name default-directory))
         (parent (dirvish--get-parent-path current))
         (parent-dirs ())
         (depth (or (car (dv-layout dv)) 0))
         (i 0))
    (dirvish-setup)
    (when (window-parameter (selected-window) 'window-side)
      (setq-local window-size-fixed 'width))
    (while (and (< i depth) (not (string= current parent)))
      (setq i (1+ i))
      (push (cons current parent) parent-dirs)
      (setq current (dirvish--get-parent-path current))
      (setq parent (dirvish--get-parent-path parent)))
    (when (> depth 0)
      (let* ((parent-width (nth 1 (dv-layout dv)))
             (remain (- 1 (nth 2 (dv-layout dv)) parent-width))
             (width (min (/ remain depth) parent-width))
             (dired-after-readin-hook nil))
        (cl-dolist (parent-dir parent-dirs)
          (let* ((current (car parent-dir))
                 (parent (cdr parent-dir))
                 (win-alist `((side . left)
                              (inhibit-same-window . t)
                              (window-width . ,width)
                              (window-parameters . ((no-other-window . t)))))
                 (buffer (dirvish--find-entry dv parent t))
                 (window (display-buffer buffer `(dirvish--display-buffer . ,win-alist))))
            (with-selected-window window
              (dirvish-prop :child current)
              (dirvish-setup)
              ;; always hide details in parent windows
              (let (dired-hide-details-mode-hook) (dired-hide-details-mode t)))))))))

(defun dirvish--init-util-buffers (dv)
  "Initialize util buffers for DV."
  (with-current-buffer (dirvish--util-buffer 'preview dv)
    (setq cursor-type nil)
    (setq mode-line-format nil)
    (add-hook 'window-scroll-functions #'dirvish-apply-ansicolor-h nil t))
  (with-current-buffer (dirvish--util-buffer 'header dv)
    (dirvish-prop :dv dv)
    (setq cursor-type nil)
    (setq window-size-fixed 'height)
    (setq mode-line-format nil))
  (with-current-buffer (dirvish--util-buffer 'footer dv)
    (dirvish-prop :dv dv)
    (setq cursor-type nil)
    (setq window-size-fixed 'height)
    (setq header-line-format nil)
    (setq mode-line-format (dv-mode-line-format dv))))

(defun dirvish--print-directory-sentinel (proc _exit)
  "Parse the directory metadata from PROC's output STR."
  (let* ((buf (process-get proc 'dv-buf))
         (vec (process-get proc 'vec))
         (append (process-get proc 'append))
         (str (with-current-buffer (process-buffer proc) (buffer-string)))
         (info (if vec (split-string str "\n") (read str))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (unless (or vec append) (setq dirvish--attrs-hash (cdr info)))
        (if vec
            (dolist (file (and (> (length info) 2) (cl-subseq info 2 -1)))
              (cl-destructuring-bind
                  (inode priv lnum user group size date time &rest path)
                  (split-string file)
                (let* ((symlinkp (cl-position "->" path :test #'equal))
                       (f-name (string-join (cl-subseq path 0 symlinkp) " "))
                       (f-base (file-name-base f-name))
                       (f-mtime (concat date " " time))
                       (f-truename (and symlinkp (string-join (cl-subseq path (1+ symlinkp)) " ")))
                       (f-dirp (string-prefix-p "d" priv))
                       (f-attr-type (or f-truename f-dirp)))
                  (when (equal f-base ".git") (dirvish-prop :vc-backend 'Git)) ; TODO: other backends
                  (dirvish-attribute-cache f-name :builtin
                    (list f-attr-type lnum user group nil f-mtime nil size priv nil inode))
                  (dirvish-attribute-cache f-name :type
                    (cons (if f-dirp 'dir 'file) f-truename)))))
          (if append (maphash (lambda (k v) (puthash k v dirvish--attrs-hash)) (cdr info))
            (dirvish-prop :vc-backend (car info))))
        (unless append (run-hooks 'dirvish-setup-hook))
        (unless (derived-mode-p 'wdired-mode) (dirvish-update-body-h)))))
  (delete-process proc)
  (kill-buffer (process-buffer proc)))

(defsubst dirvish--directory-printer (entry)
  "Compose attributes printer for ENTRY."
  `(with-temp-buffer
     (let ((hash (make-hash-table :test #'equal))
           (bk ,(and (featurep 'dirvish-vc)
                     `(ignore-errors (vc-responsible-backend ,entry)))))
       (dolist (file (directory-files ,entry t nil t))
         (let* ((attrs (file-attributes file))
                (state (and bk (vc-state-refresh file bk)))
                (git (and (eq bk 'Git) ; TODO: refactor this
                          (shell-command-to-string
                           (format "git log -1 --pretty=%%s %s" file))))
                (tp (nth 0 attrs)))
           (cond
            ((eq t tp) (setq tp '(dir . nil)))
            (tp (setq tp `(,(if (file-directory-p tp) 'dir 'file) . ,tp)))
            (t (setq tp '(file . nil))))
           (puthash file `(:builtin ,attrs :type ,tp
                                    ,@(and state (list :vc-state state))
                                    ,@(and git (list :git-msg git)))
                    hash)))
       (prin1 (cons bk hash) (current-buffer)))
     (buffer-substring-no-properties (point-min) (point-max))))

(defun dirvish--print-directory (vec buffer entry &optional append)
  "Fetch `file-attributes' for files in ENTRY, stored locally in BUFFER.
If VEC, the attributes are retrieved by parsing the output of
`ls'.  If APPEND, append the results to the existing hash table."
  (when (or (not vec) (dirvish--host-in-whitelist-p vec))
    (let* ((process-connection-type nil)
           (outbuf (dirvish--util-buffer (make-temp-name "print-dir-")))
           (switches "-1la --human-readable --time-style=long-iso --inode")
           (entry (file-local-name entry))
           (msg `(message "%s" ,(dirvish--directory-printer entry)))
           (cmd (if vec (format "ls %s %s &" switches entry) (format "%S" msg)))
           (async-shell-command-buffer nil) ; it's a hack for buffer reuse
           (display-buffer-alist
            '(("\\*Dirvish-print-dir.*\\*" (display-buffer-no-window))))
           (proc (if vec (tramp-handle-shell-command cmd outbuf)
                   (start-process (buffer-name outbuf) outbuf
                                  "emacs" "-q" "-batch" "--eval" cmd))))
      (process-put proc 'dv-buf buffer)
      (process-put proc 'vec vec)
      (process-put proc 'append append)
      (set-process-sentinel proc #'dirvish--print-directory-sentinel))))

(defun dirvish--build (dv)
  "Build layout for Dirvish session DV."
  (let* ((layout (dv-layout dv))
         (style (intern (format "%s-%s"
                                (if (dirvish-prop :fd-dir) "global"
                                  dirvish-header-line-position)
                                dirvish-mode-line-position)))
         (order (cl-case (if layout style 'none)
                  ('none            '())
                  ('default-default '(preview header footer))
                  ('default-disable '(preview header))
                  ('default-global  '(footer preview header))
                  ('disable-default '(preview footer))
                  ('disable-disable '(preview))
                  ('disable-global  '(footer preview))
                  ('global-default  '(header preview footer))
                  ('global-disable  '(header preview))
                  ('global-global   '(footer header preview))))
         (w-actions
          `((preview (side . right) (window-width . ,(nth 2 layout)))
            (header (side . above) (window-height . -2)
                    (window-parameters . ((no-other-window . t))))
            (footer (side . below) (window-height . -2)
                    (window-parameters . ((no-other-window . t))))))
         maybe-abnormal)
    (dirvish--init-util-buffers dv)
    (if (not order)
        (dirvish--create-parent-windows dv)
      (let ((ignore-window-parameters t)) (delete-other-windows))
      (dolist (pane order)
        (let* ((inhibit-modification-hooks t)
               (buf (dirvish--util-buffer pane dv))
               (win-alist (alist-get pane w-actions))
               (new-window (display-buffer
                            buf `(dirvish--display-buffer . ,win-alist))))
          (cond ((eq pane 'preview) (setf (dv-preview-window dv) new-window))
                (t (set-window-dedicated-p new-window t)
                   (push new-window maybe-abnormal)))
          (set-window-buffer new-window buf)))
      (dirvish--create-parent-windows dv))
    (let ((h-fmt (if (dirvish-prop :fd-dir)
                     `(:eval (format-mode-line
                              dirvish--search-switches nil nil
                              (and (buffer-live-p ,(current-buffer))
                                   ,(current-buffer))))
                   (dv-header-line-format dv)))
          (vec (dirvish-prop :tramp)))
      (with-current-buffer (dirvish--util-buffer 'header dv)
        (setq header-line-format h-fmt))
      (dirvish--normalize-util-windows maybe-abnormal)
      (when (and layout (not vec)) (dirvish-cache-images dv))
      (unless (or (dirvish-prop :fd-dir) (dirvish-prop :cached))
        (dirvish--print-directory vec (current-buffer) default-directory)
        (dirvish-prop :cached t)))))

(define-derived-mode dirvish-mode dired-mode "Dirvish"
  "Convert Dired buffer to a Dirvish buffer."
  :group 'dirvish :interactive nil)

;;;; Commands

(defun dirvish-cache-images (&optional dv)
  "Cache image/video-thumbnail for index directory in DV.
If called interactively, ignore the directory files count limit
in `dirvish-auto-cache-threshold'."
  (interactive)
  (setq dv (or dv (dirvish-curr)))
  (with-current-buffer (window-buffer (dv-root-window dv))
    (when (or (called-interactively-p 'any)
              (< (length (dirvish-prop :files)) (car dirvish-auto-cache-threshold)))
      (cl-loop
       with win = (dv-preview-window dv)
       with width = (window-width win)
       for file in (dirvish-prop :files)
       for ext = (downcase (or (file-name-extension file) ""))
       for (cmd . args) = (cl-loop
                           for fn in dirvish--cache-img-fns
                           for (type . payload) = (funcall fn file ext win dv)
                           thereis (and (eq type 'image-cache) payload))
       when cmd do (push (cons (format "%s-%s-img-cache" file width)
                               (list file width cmd args))
                         dirvish--cache-pool)))))

(defun dirvish-toggle-fullscreen ()
  "Toggle fullscreen of current Dirvish."
  (interactive)
  (let* ((dv (dirvish-curr))
         (old-layout (dv-layout dv))
         (new-layout (unless old-layout (dv-last-fs-layout dv)))
         (buf (current-buffer)))
    (if old-layout
        (set-window-configuration (dv-window-conf dv))
      (with-selected-window (dv-root-window dv)
        (let (quit-window-hook) (quit-window))))
    (setf (dv-layout dv) new-layout)
    (setf (dv-window-conf dv) (current-window-configuration))
    (with-selected-window (dirvish--create-root-window dv)
      (dirvish-with-no-dedication (switch-to-buffer buf))
      (dirvish-reclaim)
      (dirvish--build dv)
      (dirvish-debounce layout (dirvish-preview-update)))))

;;;###autoload
(define-minor-mode dirvish-override-dired-mode
  "Let Dirvish take over Dired globally."
  :group 'dirvish :global t
  (if dirvish-override-dired-mode
      (progn
        (pcase-dolist (`(,type ,sym ,fn ,place) dirvish-advice-alist)
          (if (eq type 'hook) (add-hook sym fn) (advice-add sym place fn)))
        (setq find-directory-functions
              (cl-substitute #'dirvish--noselect #'dired-noselect find-directory-functions)))
    (pcase-dolist (`(,type ,sym ,fn) dirvish-advice-alist)
      (if (eq type 'hook) (remove-hook sym fn) (advice-remove sym fn)))
    (setq find-directory-functions
          (cl-substitute #'dired-noselect #'dirvish--noselect find-directory-functions))))

;;;###autoload
(defun dirvish (&optional path)
  "Start a full frame Dirvish session with optional PATH.
If called with \\[universal-arguments], prompt for PATH,
otherwise it defaults to variable `buffer-file-name'."
  (interactive (list (and current-prefix-arg (read-file-name "Dirvish: "))))
  (setq path (or path default-directory))
  (or (dirvish--reuse-session path 'full)
      (dirvish-new t :path path :layout dirvish-default-layout)))

;;;###autoload (autoload 'dirvish-dispatch "dirvish" nil t)
(transient-define-prefix dirvish-dispatch ()
  "Main help menu for Dired/Dirvish."
  [:description
   (lambda () (propertize "Dirvish Help Menu" 'face '(:inherit dired-mark :underline t) 'display '((height 1.3))))
   ["Essential commands"
    ("e" "  Open file"              dired-find-file)
    ("o" "  Open file other window" dired-find-file-other-window)
    ("/" "  Search for files"       dirvish-fd)
    ("s" "  Sort current buffer"    dirvish-quicksort)
    ("g" "  Refresh buffer"         revert-buffer)
    ("M-s" "Setup Dirvish"          dirvish-setup-menu)
    ("TAB" "Toggle subtree"         dirvish-subtree-toggle)
    ("M-f" "Toggle fullscreen"      dirvish-toggle-fullscreen)]
   ["File operations"
    ("a" "  Add an empty file"      dired-create-empty-file)
    ("+" "  Add a directory"        dired-create-directory)
    ("@" "  Rename files"           dirvish-renaming-menu)
    ("X" "  Delete files"           dired-do-delete)
    ("v" "  View this file"         dired-view-file)
    ("y" "  Yank marked files"      dirvish-yank-menu)
    ("." "  Manage pinned groups"   dirvish-emerge-menu)
    ("*" "  Manage marks"           dirvish-mark-menu)]]
  [["Navigation"
    ("j" "  Goto to line for file"  dired-goto-file)
    ("b" "  Jump to bookmarks"      dirvish-bookmark-jump)
    ("^" "  Go to parent directory" dired-up-directory)
    ("r" "  Roam the file system"   dirvish-fd-roam)
    ("m" "  Go to the MRU buffer"   dirvish-history-last)
    ("n" "  Forward history"        dirvish-history-go-forward :transient t)
    ("p" "  Backward history"       dirvish-history-go-backward :transient t)
    ("SPC" "Recently visited"       dirvish-history-jump)]
   ["Others"
    ("l" "  Setup listing switches" dirvish-ls-switches-menu)
    ("f" "  Setup fd switches"      dirvish-fd-switches-menu :if (lambda () dirvish-fd-actual-switches))
    ("i" "  Get file information"   dirvish-file-info-menu)
    ("S" "  Manage subdirs"         dirvish-subdir-menu)
    ("(" "  Toggle details"         dired-hide-details-mode)
    ("=" "  Compare files"          dired-diff)
    (":" "  GnuPG helpers"          dirvish-epa-dired-menu)
    ("N" "  Live narrowing"         dirvish-narrow)]]
  (interactive) (when (derived-mode-p 'dired-mode) (transient-setup 'dirvish-dispatch)))

(provide 'dirvish)
;;; dirvish.el ends here
