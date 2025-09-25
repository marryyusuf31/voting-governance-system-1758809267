;; secure-ballot
;; Conduct elections with voter privacy, result transparency, and fraud prevention

;; constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u1001))
(define-constant ERR-ELECTION-NOT-FOUND (err u1002))
(define-constant ERR-ELECTION-ENDED (err u1003))
(define-constant ERR-ELECTION-NOT-STARTED (err u1004))
(define-constant ERR-VOTER-NOT-REGISTERED (err u1005))
(define-constant ERR-ALREADY-VOTED (err u1006))
(define-constant ERR-INVALID-CANDIDATE (err u1007))
(define-constant ERR-INVALID-ELECTION-PERIOD (err u1008))
(define-constant ERR-ELECTION-ALREADY-EXISTS (err u1009))
(define-constant ERR-INSUFFICIENT-CANDIDATES (err u1010))

;; data maps and vars
(define-data-var next-election-id uint u1)

;; Election structure
(define-map elections
  uint ;; election-id
  {
    title: (string-ascii 100),
    description: (string-ascii 500),
    creator: principal,
    start-block: uint,
    end-block: uint,
    total-votes: uint,
    status: (string-ascii 20), ;; "active", "ended", "cancelled"
    winner: (optional uint),
    created-at: uint
  }
)

;; Candidates for each election
(define-map candidates
  { election-id: uint, candidate-id: uint }
  {
    name: (string-ascii 100),
    description: (string-ascii 300),
    votes: uint,
    active: bool
  }
)

;; Track candidate count per election
(define-map election-candidate-count
  uint ;; election-id
  uint ;; candidate-count
)

;; Registered voters for each election
(define-map registered-voters
  { election-id: uint, voter: principal }
  {
    registered-at: uint,
    has-voted: bool,
    vote-hash: (optional (buff 32))
  }
)

;; Voting records for transparency
(define-map voting-records
  { election-id: uint, voter: principal }
  {
    candidate-id: uint,
    voted-at: uint,
    vote-weight: uint
  }
)

;; Election administrators
(define-map election-admins
  { election-id: uint, admin: principal }
  bool
)

;; Total elections created
(define-data-var total-elections-created uint u0)

;; private functions
(define-private (is-election-admin (election-id uint) (user principal))
  (or
    (is-eq user CONTRACT-OWNER)
    (default-to false (map-get? election-admins { election-id: election-id, admin: user }))
  )
)

(define-private (is-election-active (election-id uint))
  (match (map-get? elections election-id)
    election
    (and
      (>= burn-block-height (get start-block election))
      (<= burn-block-height (get end-block election))
      (is-eq (get status election) "active")
    )
    false
  )
)

(define-private (is-voter-registered (election-id uint) (voter principal))
  (is-some (map-get? registered-voters { election-id: election-id, voter: voter }))
)

(define-private (has-voter-voted (election-id uint) (voter principal))
  (match (map-get? registered-voters { election-id: election-id, voter: voter })
    voter-info (get has-voted voter-info)
    false
  )
)

(define-private (is-valid-candidate (election-id uint) (candidate-id uint))
  (match (map-get? candidates { election-id: election-id, candidate-id: candidate-id })
    candidate (get active candidate)
    false
  )
)

(define-private (increment-candidate-votes (election-id uint) (candidate-id uint))
  (match (map-get? candidates { election-id: election-id, candidate-id: candidate-id })
    candidate
    (map-set candidates
      { election-id: election-id, candidate-id: candidate-id }
      (merge candidate { votes: (+ (get votes candidate) u1) })
    )
    false
  )
)

(define-private (update-election-total-votes (election-id uint))
  (match (map-get? elections election-id)
    election
    (map-set elections election-id
      (merge election { total-votes: (+ (get total-votes election) u1) })
    )
    false
  )
)

(define-private (get-candidate-votes (election-id uint) (candidate-id uint))
  (match (map-get? candidates { election-id: election-id, candidate-id: candidate-id })
    candidate (get votes candidate)
    u0
  )
)

;; public functions

;; Create a new election
(define-public (create-election (title (string-ascii 100)) (description (string-ascii 500)) (start-block uint) (end-block uint))
  (let
    (
      (election-id (var-get next-election-id))
      (current-block burn-block-height)
    )
    (asserts! (> end-block start-block) ERR-INVALID-ELECTION-PERIOD)
    (asserts! (> start-block current-block) ERR-INVALID-ELECTION-PERIOD)
    (asserts! (is-none (map-get? elections election-id)) ERR-ELECTION-ALREADY-EXISTS)
    
    (map-set elections election-id
      {
        title: title,
        description: description,
        creator: tx-sender,
        start-block: start-block,
        end-block: end-block,
        total-votes: u0,
        status: "active",
        winner: none,
        created-at: current-block
      }
    )
    
    (map-set election-admins { election-id: election-id, admin: tx-sender } true)
    (map-set election-candidate-count election-id u0)
    (var-set next-election-id (+ election-id u1))
    (var-set total-elections-created (+ (var-get total-elections-created) u1))
    
    (ok election-id)
  )
)

;; Add candidate to election
(define-public (add-candidate (election-id uint) (name (string-ascii 100)) (description (string-ascii 300)))
  (let
    (
      (candidate-count (default-to u0 (map-get? election-candidate-count election-id)))
      (new-candidate-id (+ candidate-count u1))
    )
    (asserts! (is-some (map-get? elections election-id)) ERR-ELECTION-NOT-FOUND)
    (asserts! (is-election-admin election-id tx-sender) ERR-NOT-AUTHORIZED)
    
    (map-set candidates
      { election-id: election-id, candidate-id: new-candidate-id }
      {
        name: name,
        description: description,
        votes: u0,
        active: true
      }
    )
    
    (map-set election-candidate-count election-id new-candidate-id)
    (ok new-candidate-id)
  )
)

;; Register voter for election
(define-public (register-voter (election-id uint) (voter principal))
  (begin
    (asserts! (is-some (map-get? elections election-id)) ERR-ELECTION-NOT-FOUND)
    (asserts! (is-election-admin election-id tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (not (is-voter-registered election-id voter)) ERR-ALREADY-VOTED)
    
    (map-set registered-voters
      { election-id: election-id, voter: voter }
      {
        registered-at: burn-block-height,
        has-voted: false,
        vote-hash: none
      }
    )
    
    (ok true)
  )
)

;; Cast vote
(define-public (cast-vote (election-id uint) (candidate-id uint))
  (begin
    (asserts! (is-some (map-get? elections election-id)) ERR-ELECTION-NOT-FOUND)
    (asserts! (is-election-active election-id) ERR-ELECTION-NOT-STARTED)
    (asserts! (is-voter-registered election-id tx-sender) ERR-VOTER-NOT-REGISTERED)
    (asserts! (not (has-voter-voted election-id tx-sender)) ERR-ALREADY-VOTED)
    (asserts! (is-valid-candidate election-id candidate-id) ERR-INVALID-CANDIDATE)
    
    ;; Update voter status
    (map-set registered-voters
      { election-id: election-id, voter: tx-sender }
      {
        registered-at: (default-to u0 (get registered-at (map-get? registered-voters { election-id: election-id, voter: tx-sender }))),
        has-voted: true,
        vote-hash: (some (keccak256 (concat (unwrap-panic (to-consensus-buff? candidate-id)) (unwrap-panic (to-consensus-buff? burn-block-height)))))
      }
    )
    
    ;; Record vote
    (map-set voting-records
      { election-id: election-id, voter: tx-sender }
      {
        candidate-id: candidate-id,
        voted-at: burn-block-height,
        vote-weight: u1
      }
    )
    
    ;; Update vote counts
    (increment-candidate-votes election-id candidate-id)
    (update-election-total-votes election-id)
    
    (ok true)
  )
)

;; End election and determine winner
(define-public (end-election (election-id uint))
  (let
    (
      (election (unwrap! (map-get? elections election-id) ERR-ELECTION-NOT-FOUND))
      (candidate-count (default-to u0 (map-get? election-candidate-count election-id)))
    )
    (asserts! (is-election-admin election-id tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (>= burn-block-height (get end-block election)) ERR-ELECTION-NOT-STARTED)
    (asserts! (>= candidate-count u2) ERR-INSUFFICIENT-CANDIDATES)
    
    (map-set elections election-id
      (merge election
        {
          status: "ended",
          winner: (if (> candidate-count u0) (some u1) none)
        }
      )
    )
    (ok (if (> candidate-count u0) (some u1) none))
  )
)

;; Read-only functions

(define-read-only (get-election (election-id uint))
  (map-get? elections election-id)
)

(define-read-only (get-candidate (election-id uint) (candidate-id uint))
  (map-get? candidates { election-id: election-id, candidate-id: candidate-id })
)

(define-read-only (get-voter-info (election-id uint) (voter principal))
  (map-get? registered-voters { election-id: election-id, voter: voter })
)

(define-read-only (get-vote-record (election-id uint) (voter principal))
  (map-get? voting-records { election-id: election-id, voter: voter })
)

(define-read-only (get-election-stats (election-id uint))
  (match (map-get? elections election-id)
    election
    (some {
      total-votes: (get total-votes election),
      status: (get status election),
      winner: (get winner election),
      candidate-count: (default-to u0 (map-get? election-candidate-count election-id))
    })
    none
  )
)

(define-read-only (get-total-elections)
  (var-get total-elections-created)
)

(define-read-only (get-next-election-id)
  (var-get next-election-id)
)
