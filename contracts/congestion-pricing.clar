;; Congestion Pricing Contract
;; Manages dynamic pricing for high-traffic areas

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-INVALID-ZONE (err u201))
(define-constant ERR-INSUFFICIENT-PAYMENT (err u202))
(define-constant ERR-INVALID-PRICING (err u203))

;; Data Variables
(define-data-var total-zones uint u0)
(define-data-var base-fee uint u1000000) ;; 1 STX in microSTX

;; Data Maps
(define-map pricing-zones
  { zone-id: uint }
  {
    name: (string-ascii 50),
    base-price: uint,
    multiplier: uint,
    is-active: bool,
    created-at: uint
  }
)

(define-map zone-congestion
  { zone-id: uint, hour: uint }
  {
    congestion-level: uint,
    current-multiplier: uint,
    vehicles-entered: uint,
    total-fees-collected: uint
  }
)

(define-map vehicle-entries
  { vehicle-id: (string-ascii 20), zone-id: uint }
  {
    entry-time: uint,
    fee-paid: uint,
    exit-time: (optional uint)
  }
)

;; Public Functions

;; Create new pricing zone
(define-public (create-pricing-zone (name (string-ascii 50)) (base-price uint))
  (let ((zone-id (+ (var-get total-zones) u1)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (> base-price u0) ERR-INVALID-PRICING)

    (map-set pricing-zones
      { zone-id: zone-id }
      {
        name: name,
        base-price: base-price,
        multiplier: u100, ;; 100% = 1.0x
        is-active: true,
        created-at: block-height
      }
    )

    (var-set total-zones zone-id)
    (ok zone-id)
  )
)

;; Vehicle enters congestion zone
(define-public (enter-zone (vehicle-id (string-ascii 20)) (zone-id uint))
  (let ((zone (unwrap! (map-get? pricing-zones { zone-id: zone-id }) ERR-INVALID-ZONE))
        (current-hour (mod block-height u24))
        (current-fee (calculate-current-fee zone-id)))

    (asserts! (get is-active zone) ERR-INVALID-ZONE)
    (asserts! (>= (stx-get-balance tx-sender) current-fee) ERR-INSUFFICIENT-PAYMENT)

    ;; Transfer fee
    (try! (stx-transfer? current-fee tx-sender CONTRACT-OWNER))

    ;; Record entry
    (map-set vehicle-entries
      { vehicle-id: vehicle-id, zone-id: zone-id }
      {
        entry-time: block-height,
        fee-paid: current-fee,
        exit-time: none
      }
    )

    ;; Update zone statistics
    (update-zone-stats zone-id current-hour current-fee)

    (ok current-fee)
  )
)

;; Vehicle exits congestion zone
(define-public (exit-zone (vehicle-id (string-ascii 20)) (zone-id uint))
  (let ((entry (unwrap! (map-get? vehicle-entries { vehicle-id: vehicle-id, zone-id: zone-id }) ERR-INVALID-ZONE)))

    (map-set vehicle-entries
      { vehicle-id: vehicle-id, zone-id: zone-id }
      (merge entry { exit-time: (some block-height) })
    )

    (ok true)
  )
)

;; Update congestion multiplier
(define-public (update-congestion-multiplier (zone-id uint) (new-multiplier uint))
  (let ((zone (unwrap! (map-get? pricing-zones { zone-id: zone-id }) ERR-INVALID-ZONE)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= new-multiplier u50) (<= new-multiplier u500)) ERR-INVALID-PRICING)

    (map-set pricing-zones
      { zone-id: zone-id }
      (merge zone { multiplier: new-multiplier })
    )

    (ok true)
  )
)

;; Read-only Functions

;; Get pricing zone details
(define-read-only (get-pricing-zone (zone-id uint))
  (map-get? pricing-zones { zone-id: zone-id })
)

;; Get current fee for zone
(define-read-only (get-current-fee (zone-id uint))
  (calculate-current-fee zone-id)
)

;; Get zone congestion data
(define-read-only (get-zone-congestion (zone-id uint) (hour uint))
  (map-get? zone-congestion { zone-id: zone-id, hour: hour })
)

;; Get vehicle entry record
(define-read-only (get-vehicle-entry (vehicle-id (string-ascii 20)) (zone-id uint))
  (map-get? vehicle-entries { vehicle-id: vehicle-id, zone-id: zone-id })
)

;; Private Functions

;; Calculate current fee based on congestion
(define-private (calculate-current-fee (zone-id uint))
  (match (map-get? pricing-zones { zone-id: zone-id })
    zone
    (let ((base-price (get base-price zone))
          (multiplier (get multiplier zone)))
      (/ (* base-price multiplier) u100)
    )
    u0
  )
)

;; Update zone statistics
(define-private (update-zone-stats (zone-id uint) (hour uint) (fee-collected uint))
  (let ((current-stats (default-to
                         { congestion-level: u0, current-multiplier: u100, vehicles-entered: u0, total-fees-collected: u0 }
                         (map-get? zone-congestion { zone-id: zone-id, hour: hour }))))

    (map-set zone-congestion
      { zone-id: zone-id, hour: hour }
      {
        congestion-level: (+ (get congestion-level current-stats) u1),
        current-multiplier: (get current-multiplier current-stats),
        vehicles-entered: (+ (get vehicles-entered current-stats) u1),
        total-fees-collected: (+ (get total-fees-collected current-stats) fee-collected)
      }
    )
  )
)
