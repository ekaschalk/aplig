;;; nt-note.el --- Notation Overlays -*- lexical-binding: t; -*-

;; Copyright © 2019 Eric Kaschalk <ekaschalk@gmail.com>

;;; Commentary:

;; Notation overlay management, instantiation, etc.

;;; Code:
;;;; Requires

(require 'nt-base)

(require 'nt-mask)
(require 'nt-ov)

;;; Configuration
;;;; Managed

(defvar nt-notes nil
  "Start-position-ordered list of note overlays.")


(defvar-local nt-note--init-in-progress? nil
  "Are we instantiating the initial notes?")

;;; Access
;;;; Fundamentals

(defun nt-note<-pos (pos)
  "Get note at POS."
  (-some->> pos overlays-at (-filter #'nt-ov--note?) car))

(defun nt-notes<-region (start end)
  "Get notes in START and END."
  (-some->> (overlays-in start end) (-filter #'nt-ov--note?) nt-notes--sort))

;;;; Extensions

(defun nt-note--at-point ()
  "Get note at point."
  (-> (point) nt-note<-pos))

(defun nt-notes<-line (line)
  "Get notes on LINE."
  (-some->> line nt-line->region (apply #'nt-notes<-region)))

(defun nt-notes<-lines (start-line end-line)
  "Get notes in [START-LINE END-LINE)."
  (-some->> (nt-lines->region start-line end-line) (apply #'nt-notes<-region)))

;;; Transforms
;;;; Wrappers

(defun nt-note->width (note)
  "Access NOTE's width."
  (-some-> note (overlay-get 'nt-width)))

(defun nt-note->parens (note)
  "Access NOTE's parens."
  (-some-> note (overlay-get 'nt-parens)))

(defun nt-note->last-bound (note)
  "Access NOTE's last calculated bound."
  (-some-> note (overlay-get 'nt-last-bound)))

(defun nt-note->replacement (note)
  "Access NOTE's display."
  (-some-> note (overlay-get 'display)))

(defun nt-note--in-effect? (note)
  "Access NOTE's status of indentation contribution."
  (-some-> note (overlay-get 'nt-in-effect?)))

;;;; Masks

(defun nt-note->interval (note)
  "Get line interval [note-start-line bound) of NOTE."
  (list (1+ (nt-ov->line note))
        (nt-note->last-bound note)))

(defun nt-note->masks (note)
  "Gets all masks NOTE contributes to."
  (when (nt-note--in-effect? note)
    (apply #'nt-masks<-lines (nt-note->interval note))))

;;;; Misc

(defun nt-notes->width (notes)
  "Sum NOTES' widths."
  (->> notes (-map #'nt-note->width) -sum))

(defun nt-note->depth (note)
  "Get parenthetical depth of NOTE."
  (-some-> note nt-note->parens length))

(defun nt-note->idx (note)
  "Get index of insertion of new NOTE into `nt-notes'."
  (or (-find-index (-partial #'nt-notes--lt note) nt-notes)
      (length nt-notes)))

;;; Relationships
;;;; Comparisons

(defun nt-notes--lt (self other)
  "Compare lt two notes buffer positions."
  (funcall (-on #'< #'overlay-start) self other))

(defun nt-notes--bound-lt (self other)
  "Compare lt two note's bounds."
  (funcall (-on #'< #'nt-note->last-bound) self other))

(defun nt-notes--sort (notes)
  "Return NOTES sorted according to start position."
  (-sort #'nt-notes--lt notes))

;;;; Roots

(defun nt-notes->roots-1 (notes roots)
  "Internal, mutually-recursive component of `nt-notes->roots'."
  (-let* (((root)
           roots)
          (root-bound
           (nt-note->last-bound root))
          (next
           (-drop-while (-compose (-partial #'>= root-bound)
                                  #'nt-note->last-bound)
                        notes)))
    (nt-notes->roots next roots)))

(defun nt-notes->roots (notes &optional roots)
  "Return ROOTS of NOTES, ie. the set of notes with largest disjoint intervals.

If 2+ roots have equiv. bounds, the first by buffer position is the only root."
  (-let (((root . rest) notes))
    (cond (rest (nt-notes->roots-1 rest (cons root roots)))
          (root (nt-notes->roots   rest (cons root roots)))
          ((reverse roots)))))

(defun nt-notes->maximal-intervals (notes)
  "Return maximal disjoint intervals of NOTES."
  (->> notes nt-notes->roots (-map #'nt-note->interval)))

;;; Management
;;;; Insertion

(defun nt-note--insert-sorted (note)
  "Get `nt-notes' with NOTE inserted maintaining order."
  (-> note nt-note->idx (-insert-at note nt-notes)))

(defun nt-note--insert (note)
  "Insert NOTE into `nt-notes' according to the current context."
  (if nt-note--init-in-progress?
      (!cons note nt-notes)
    (setq nt-notes (nt-note--insert-sorted note))))

;;;; Deletion
;;;;; Internal

(defun nt-notes--delete-internal (notes)
  "Delete NOTES overlays. Internal-use by other deletion methods only."
  (-each notes #'delete-overlay)
  (setq nt-notes (-remove #'nt-ov--deleted? nt-notes)))

(defun nt-note--delete-internal (note)
  "Delete a single NOTE overlay. Internal-use by other deletion methods only."
  (nt-notes--delete-internal (list note)))

;;;;; Commands

(defun nt-notes--delete (notes)
  "Delete NOTES, updating masks."
  (let ((intervals (nt-notes->maximal-intervals notes)))
    (-each notes #'nt-note--delete-internal)
    (-each intervals (-applify #'nt-masks--refresh-lines))))

(defun nt-note--delete (note)
  "Delete a single NOTE, updating masks."
  (nt-notes--delete (list note)))

(defun nt-notes--delete-region (start end)
  "Delete notes in START and END, updating masks."
  (nt-notes--delete (nt-notes<-region start end)))

;;; Decomposition

(defun nt-note--decompose (note)
  "Workhorse of `nt-note--decompose-hook'."
  ;; A separate func b.c. might not be this simple in full generality/optimized
  (nt-note--delete note))

(defun nt-note--decompose-hook (note post-modification? start end &optional _)
  "Decompose NOTE upon modification as a modification-hook."
  (when post-modification?
    (nt-note--decompose note)))

;;; Update Masks
;;;; Common

(defun nt-notes--doto-bound (notes doto-bound-fn)
  "Execute DOTO-BOUND-FN on NOTES, with batch mask refreshing optimized."
  ;; FIXME Why is the batch version not refreshing like expected?
  ;; (let ((nt-mask--wait-for-refresh? t))
  ;;   (-each notes doto-bound-fn))

  (let ((intervals (nt-notes->maximal-intervals notes)))
    (-each notes doto-bound-fn)
    (-each intervals (-applify #'nt-masks--refresh-lines))))

;;;; Adding Notes

(defun nt-note--add-to-mask (note mask)
  "Add NOTE to a MASK, possibly refresh mask, and return back mask."
  (push note (overlay-get mask 'nt-notes))
  (nt-mask--refresh mask))

(defun nt-note--add-to-masks (note masks)
  "Add NOTE to MASKS, possibly refresh, and return back masks."
  (->> masks
     (-remove (-partial #'nt-mask--contains? note))
     (-map (-partial #'nt-note--add-to-mask note))))

(defun nt-note--add-bounded (note)
  "Add NOTE to masks within its bound, possibly refresh, and return back masks."
  (nt-note--add-to-masks note (nt-note->masks note)))

(defun nt-notes--add-bounded (notes)
  "Add NOTES to masks within their bounds, with optimized batch refreshing."
  (nt-notes--doto-bound notes #'nt-note--add-bounded))

;;;; Removing Notes

(defun nt-note--remove-from-mask (note mask)
  "Remove NOTE from a MASK, possibly refresh, and return back mask."
  (setf (overlay-get mask 'nt-notes)
        (delete note (overlay-get mask 'nt-notes)))
  (nt-mask--refresh mask))

(defun nt-note--remove-from-masks (note masks)
  "Remove NOTE from MASKS, possibly refresh, and return back masks."
  (-map (-partial #'nt-note--remove-from-mask note) masks))

(defun nt-note--remove-bounded (note)
  "Remove NOTE from masks within its bound, maybe refresh, and give back masks."
  (nt-note--remove-from-masks note (nt-note->masks note)))

(defun nt-notes--remove-bounded (notes)
  "Remove NOTES from masks within their bounds, maybe refresh, and give masks."
  (nt-notes--doto-bound notes #'nt-note--remove-bounded))

;;;; Boundary Updates
;;;;; Fixed

(defun nt-note--extend-bound (note count)
  "Extend NOTE's 'nt-last-bound by COUNT."
  (cl-incf (overlay-get note 'nt-last-bound) count))

(defun nt-notes--extend-bounds-past (pos count)
  "Extend 'nt-last-bound by COUNT for all notes past POS and refresh masks."
  (let* ((start (save-excursion (goto-char pos) (forward-line) (point)))
         (notes (nt-notes<-region start (point-max))))
    (--each notes (nt-note--extend-bound it count)))

  (nt-masks--refresh-region pos (point-max)))

;;;;; Indeterminate

(defun nt-note--update-bounded (note)
  "Recalculate bound-based properties and update masks based on the difference."
  (let ((last-bound (nt-note->last-bound note))
        (was-in-effect? (nt-note--in-effect? note))
        (bound (nt-bound note))
        (in-effect? (nt-bound? note)))

    (when was-in-effect?
      (nt-note--remove-bounded note))

    (-doto note
      (overlay-put 'nt-last-bound bound)
      (overlay-put 'nt-in-effect? in-effect?))

    (when in-effect?
      (nt-note--add-bounded note))))

(defun nt-notes--update-bounded (notes)
  "Recalculate bound-based props/update masks of NOTES."
  (-> notes
     nt-notes--sort  ; just-in-case, I /think/ it must be sorted
     (nt-notes--doto-bound #'nt-note--update-bounded)))

(defun nt-notes--update-bounded-region (start end)
  "Recalculate bound-based props/update masks of notes within START and END."
  (nt-notes--update-bounded (nt-notes<-region start end)))

(defun nt-notes--update-bounded-buffer ()
  "Recalculate bound-based props/update masks of all notes in the buffer."
  (nt-notes--update-bounded-region (point-min) (point-max)))

;;; Init

(defun nt-note--init-bound (note)
  "Init NOTE's 'nt-bound and 'nt-in-effect? text properties."
  (-doto note
    (overlay-put 'nt-last-bound (nt-bound note))
    (overlay-put 'nt-in-effect? (nt-bound? note))))

(defun nt-note--init-ov (string replacement start end)
  "Instantiate note overlay and its properties for `nt-note--init'.

Notate Text Properties
  'nt?:           A notate overlay.
  'nt-note?:      A note overlay.
  'nt-width:      Difference of true and rendered string sizes.
  'nt-parens:     Positions of open parens containing note, outermost first.
  'nt-last-bound: The last calculated value of bound for the note.
  'nt-in-effect?: The last calculated value of bound? for the note.
"
  (-doto (make-overlay start end)
    (overlay-put 'nt?      t)
    (overlay-put 'nt-note? t)
    (overlay-put 'nt-width (- (length string) (length replacement)))
    (overlay-put 'nt-parens (nt-syntax--parens-at))

    ;; TODO Investigate effects of 'intangible (emacs docs says be careful)
    (overlay-put 'display replacement)
    (overlay-put 'modification-hooks '(nt-note--decompose-hook))

    (nt-note--init-bound)))

(defun nt-note--init (string replacement start end)
  "Build note overlay for STRING to REPLACEMENT between START and END."
  (-doto (nt-note--init-ov string replacement start end)
    (nt-note--insert)
    (nt-note--add-bounded)))

(defun nt-notes--init ()
  "Instantiate `nt-notes', ie. wrap `font-lock-ensure' with optimizations."
  (let ((nt-note--init-in-progress? t)
        (nt-mask--wait-for-refresh? t))
    (font-lock-ensure))

  ;; Ordering `nt-notes' only matters after notes are instantiated, !consing it
  (setq nt-notes (reverse nt-notes))
  (nt-masks--refresh-buffer))

;;; NOTE TREE IMPLEMENTATION

;; THIS SECTION IS UNDER DEVELOPMENT AS A SCALABLE SOLUTION.

;; The requirements of a proof-of-concept and works-without-slowing-everything
;; solution (while modifying the buffer) are vastly different.

;; Building a tree of notes with a particular structure has more complexity
;; and cost in terms of implementing - but as a result, many operations become
;; much more straightforward and have to search very little to find
;; the appropriate notes to look at for when modifying the buffer.

;;;; Code

;; (defun nt-tree->note (tree) (car tree))
;; (defun nt-tree->left (tree) (cadr tree))
;; (defun nt-tree->right (tree) (caddr tree))

;; Core
(defun nt-tree--new-node (note &optional left right)
  (list note left right))
(defun nt-tree--set-left (tree note &optional left right)
  (setf (cadr tree) (nt-tree--new-node note left right)))
(defun nt-tree--set-right (tree note &optional left right)
  (setf (caddr tree) (nt-tree--new-node note left right)))
                                        ;
;; Helpers
(defun nt-tree--null-right (tree)
  (setf (caddr tree) nil))
(defun nt-tree--rightmost (tree)
  ;; (-last #'identity (-iterate #'nt-tree->right tree))  ; If only it was lazy
  (let ((rightmost tree))
    (while (nt-tree->right rightmost)
      (setq rightmost (nt-tree->right tree)))
    rightmost))

;; Algorithm
(defun nt-tree--find-pivot (tree note &optional parent)
  "Follow TREE's right until first node not eaten by NOTE and separate them.

This node is called the pivot.
The start of the search is NOTE's left and the pivot is NOTE's right.

Eaten is when a new NOTE is found earlier in the buffer but its
bound extends further. The NOTE's indentation boundary then
captures all right branches until that is no longer the case.

Notice we need not consider any left branch. If a right branch is
not covered, then its entire left subtree will not be covered, as
the left subtree has all its nodes bounds lt and positions
greater than the parent."
  (-let* (((node _ right) tree)
          (pos<? (nt-notes--lt note node))
          (bound<? (nt-notes--bound-lt note node))
          (descend? (and pos<? (not bound<?))))
    (if descend?
        ;; If no right yet descending, then we are eating the entire RHS
        (when right (nt-tree--find-pivot right note tree))

      (nt-tree--null-right parent)
      tree)))

(defun nt-tree--insert (tree note &optional parent)
  "Insert NOTE into TREE, maintaining the nested-indent structure.

A NOTE should be inserted:
1. Left if its bound is less than the current node.
2. Right if its bound is greater /or equal to/ the current node.

If NOTE's indent-interval captures an existing subtree, we
rebalance. See `nt-tree--find-pivot' for details.

Observe if we build up the initial tree by ascending buffer
position of notes, during the buildup we never rebalance."
  (if (not tree)
      (nt-tree--new-node note)

    (-let* (((node left right) tree)
            (pos<? (nt-notes--lt note node))
            (bound<? (nt-notes--bound-lt note node))
            (pivot? (and pos<? (not bound<?))))
      (cond
       ((and pivot? (not parent))  ; Eating head
        (nt-tree--new-node note tree))

       (pivot?
        (let ((pivot (nt-tree--find-pivot tree note parent)))
          (nt-tree--set-right parent note tree pivot)))

       ((and bound<? left)
        (nt-tree--insert left note tree))

       (bound<?
        (nt-tree--set-left tree note))

       (right
        (nt-tree--insert right note tree))

       (t
        (nt-tree--set-right tree note))))))

(defun nt-tree--delete (tree note &optional parent)
  "Delete a single NOTE from TREE, maintaining the nested-indent structure.

Deleting a NOTE:
1. Replace its position with the LEFT subtree of the deletion.
2. Set the RIGHT of the RIGHTMOST leaf of above with the RIGHT subtree
   of the deletion."
  (-let* (((node left right) tree)
          (bound<? (nt-notes--bound-lt note node)))
    (cond ((eq note node)
           (progn
             (if (eq note (nt-tree->left parent))
                 (nt-tree--set-left parent left)
               (nt-tree--set-right parent left))

             (nt-tree--set-right (nt-tree--rightmost left) right)))

          (bound<?
           (nt-tree--delete left note tree))
          (t
           (nt-tree--delete right note tree)))))

;; Now we can get our hands dirty with the fundamentals setup
(defun nt-tree--delete-region ())
(defun nt-tree--find ())
(defun nt-tree--merge ())

;;; Provide

(provide 'nt-note)

;;; nt-note.el ends here
