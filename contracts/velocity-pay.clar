;; Title: VelocityPay Commerce Engine
;;
;; Summary: Next-generation decentralized payment orchestration platform that transforms how businesses 
;; handle Bitcoin transactions through intelligent automation and enterprise-grade settlement infrastructure
;;
;; Description: VelocityPay Commerce Engine represents the evolution of digital payments, delivering 
;; an autonomous payment processing ecosystem built on Stacks blockchain technology. This innovative 
;; platform empowers merchants with lightning-fast sBTC transaction capabilities, featuring dynamic 
;; fee optimization, intelligent invoice management, and real-time liquidity distribution. 
;;
;; Key innovations include: automated multi-party settlement protocols, reference-driven transaction 
;; orchestration, time-bound payment guarantees, and sophisticated balance management systems. 
;; The platform seamlessly integrates with existing business infrastructure through webhook 
;; notifications and API-first architecture, while maintaining institutional-grade security 
;; through cryptographic transaction validation and segregated fund management.
;;
;; Built for scale, VelocityPay handles complex payment workflows with microsecond precision,
;; enabling businesses to focus on growth while the platform manages the complexity of 
;; decentralized commerce infrastructure.
;;

;; CONSTANTS & ERROR CODES

(define-constant CONTRACT_OWNER tx-sender)

;; Error codes for comprehensive error handling
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INVALID_AMOUNT (err u101))
(define-constant ERR_PAYMENT_NOT_FOUND (err u102))
(define-constant ERR_PAYMENT_ALREADY_PROCESSED (err u103))
(define-constant ERR_PAYMENT_EXPIRED (err u104))
(define-constant ERR_INSUFFICIENT_BALANCE (err u105))
(define-constant ERR_BUSINESS_NOT_REGISTERED (err u106))
(define-constant ERR_INVALID_SIGNATURE (err u107))

;; DATA VARIABLES

(define-data-var next-payment-id uint u1)
(define-data-var platform-fee-basis-points uint u100) ;; 1% platform fee
(define-data-var fee-collector principal CONTRACT_OWNER)

;; DATA MAPS

;; Business registry with comprehensive merchant profiles
(define-map businesses
  principal
  {
    name: (string-ascii 64),
    webhook-url: (optional (string-ascii 256)),
    fee-rate: uint, ;; basis points (e.g., 250 = 2.5%)
    is-active: bool,
    total-processed: uint,
    registration-block: uint,
  }
)

;; Payment transaction records with full lifecycle tracking
(define-map payments
  uint
  {
    business: principal,
    customer: (optional principal),
    amount: uint,
    description: (string-ascii 256),
    reference-id: (string-ascii 64),
    status: (string-ascii 16), ;; "pending", "completed", "expired", "refunded"
    created-at: uint,
    expires-at: uint,
    processed-at: (optional uint),
    processor: (optional principal),
  }
)

;; Reference-based payment lookup system
(define-map payment-references
  {
    business: principal,
    reference: (string-ascii 64),
  }
  uint
)

;; Segregated business balance management
(define-map business-balances
  principal
  uint
)

;; BUSINESS MANAGEMENT FUNCTIONS

;; Register a new business entity on the platform
(define-public (register-business
    (name (string-ascii 64))
    (webhook-url (optional (string-ascii 256)))
  )
  (let ((caller tx-sender))
    (asserts! (is-none (map-get? businesses caller)) ERR_UNAUTHORIZED)
    (asserts! (> (len name) u0) ERR_INVALID_AMOUNT)
    (asserts! (<= (len name) u64) ERR_INVALID_AMOUNT)

    (map-set businesses caller {
      name: name,
      webhook-url: webhook-url,
      fee-rate: u0, ;; Default 0% business fee
      is-active: true,
      total-processed: u0,
      registration-block: stacks-block-height,
    })
    (ok true)
  )
)

;; Update existing business configuration and settings
(define-public (update-business
    (name (string-ascii 64))
    (webhook-url (optional (string-ascii 256)))
    (fee-rate uint)
  )
  (let (
      (caller tx-sender)
      (current-business (unwrap! (map-get? businesses caller) ERR_BUSINESS_NOT_REGISTERED))
    )
    (asserts! (< fee-rate u1000) ERR_INVALID_AMOUNT)
    ;; Max 10% fee
    (asserts! (> (len name) u0) ERR_INVALID_AMOUNT)
    (asserts! (<= (len name) u64) ERR_INVALID_AMOUNT)

    (map-set businesses caller
      (merge current-business {
        name: name,
        webhook-url: webhook-url,
        fee-rate: fee-rate,
      })
    )
    (ok true)
  )
)

;; PAYMENT PROCESSING FUNCTIONS

;; Create a new payment request with expiration and reference tracking
(define-public (create-payment
    (amount uint)
    (description (string-ascii 256))
    (reference-id (string-ascii 64))
    (expires-in-blocks uint)
  )
  (let (
      (caller tx-sender)
      (payment-id (var-get next-payment-id))
      (current-block stacks-block-height)
      (expiry-block (+ current-block expires-in-blocks))
    )
    ;; Comprehensive input validation
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (> expires-in-blocks u0) ERR_INVALID_AMOUNT)
    (asserts! (< expires-in-blocks u4320) ERR_INVALID_AMOUNT)
    ;; Max 30 days
    (asserts! (> (len description) u0) ERR_INVALID_AMOUNT)
    (asserts! (<= (len description) u256) ERR_INVALID_AMOUNT)
    (asserts! (> (len reference-id) u0) ERR_INVALID_AMOUNT)
    (asserts! (<= (len reference-id) u64) ERR_INVALID_AMOUNT)
    (asserts! (is-some (map-get? businesses caller)) ERR_BUSINESS_NOT_REGISTERED)
    (asserts!
      (is-none (map-get? payment-references {
        business: caller,
        reference: reference-id,
      }))
      ERR_PAYMENT_ALREADY_PROCESSED
    )

    ;; Create payment record
    (map-set payments payment-id {
      business: caller,
      customer: none,
      amount: amount,
      description: description,
      reference-id: reference-id,
      status: "pending",
      created-at: current-block,
      expires-at: expiry-block,
      processed-at: none,
      processor: none,
    })

    ;; Establish reference mapping for quick lookups
    (map-set payment-references {
      business: caller,
      reference: reference-id,
    }
      payment-id
    )

    ;; Increment payment ID counter
    (var-set next-payment-id (+ payment-id u1))
    (ok payment-id)
  )
)

;; Process customer payment with automated fee distribution
(define-public (pay-invoice (payment-id uint))
  (let (
      (caller tx-sender)
      (payment (unwrap! (map-get? payments payment-id) ERR_PAYMENT_NOT_FOUND))
      (business-data (unwrap! (map-get? businesses (get business payment))
        ERR_BUSINESS_NOT_REGISTERED
      ))
      (current-block stacks-block-height)
    )
    ;; Payment validation checks
    (asserts! (is-eq (get status payment) "pending")
      ERR_PAYMENT_ALREADY_PROCESSED
    )
    (asserts! (< current-block (get expires-at payment)) ERR_PAYMENT_EXPIRED)
    (asserts! (get is-active business-data) ERR_UNAUTHORIZED)

    ;; Dynamic fee calculation and distribution
    (let (
        (payment-amount (get amount payment))
        (platform-fee (/ (* payment-amount (var-get platform-fee-basis-points)) u10000))
        (business-fee (/ (* payment-amount (get fee-rate business-data)) u10000))
        (total-fees (+ platform-fee business-fee))
        (net-amount (- payment-amount total-fees))
      )
      ;; Execute sBTC transfer from customer
      (try! (contract-call? 'ST1F7QA2MDF17S807EPA36TSS8AMEFY4KA9TVGWXT.sbtc-token
        transfer payment-amount caller (as-contract tx-sender) none
      ))

      ;; Update segregated business balance
      (let ((current-balance (default-to u0 (map-get? business-balances (get business payment)))))
        (map-set business-balances (get business payment)
          (+ current-balance net-amount)
        )
      )

      ;; Process platform fee distribution
      (if (> platform-fee u0)
        (try! (as-contract (contract-call? 'ST1F7QA2MDF17S807EPA36TSS8AMEFY4KA9TVGWXT.sbtc-token
          transfer platform-fee tx-sender (var-get fee-collector) none
        )))
        true
      )

      ;; Update payment status to completed
      (map-set payments payment-id
        (merge payment {
          customer: (some caller),
          status: "completed",
          processed-at: (some current-block),
          processor: (some caller),
        })
      )

      ;; Update business processing statistics
      (map-set businesses (get business payment)
        (merge business-data { total-processed: (+ (get total-processed business-data) payment-amount) })
      )

      (ok {
        payment-id: payment-id,
        net-amount: net-amount,
        fees: total-fees,
      })
    )
  )
)

;; BALANCE MANAGEMENT FUNCTIONS

;; Secure business balance withdrawal with validation
(define-public (withdraw-balance (amount uint))
  (let (
      (caller tx-sender)
      (current-balance (default-to u0 (map-get? business-balances caller)))
    )
    (asserts! (is-some (map-get? businesses caller)) ERR_BUSINESS_NOT_REGISTERED)
    (asserts! (>= current-balance amount) ERR_INSUFFICIENT_BALANCE)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)

    ;; Update balance record
    (map-set business-balances caller (- current-balance amount))

    ;; Execute sBTC transfer to business
    (try! (as-contract (contract-call? 'ST1F7QA2MDF17S807EPA36TSS8AMEFY4KA9TVGWXT.sbtc-token
      transfer amount tx-sender caller none
    )))

    (ok amount)
  )
)

;; Business-initiated refund processing
(define-public (refund-payment (payment-id uint))
  (let (
      (caller tx-sender)
      (payment (unwrap! (map-get? payments payment-id) ERR_PAYMENT_NOT_FOUND))
      (customer (unwrap! (get customer payment) ERR_PAYMENT_NOT_FOUND))
    )
    (asserts! (is-eq caller (get business payment)) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status payment) "completed")
      ERR_PAYMENT_ALREADY_PROCESSED
    )

    (let (
        (refund-amount (get amount payment))
        (current-balance (default-to u0 (map-get? business-balances caller)))
      )
      (asserts! (>= current-balance refund-amount) ERR_INSUFFICIENT_BALANCE)

      ;; Deduct refund from business balance
      (map-set business-balances caller (- current-balance refund-amount))

      ;; Execute refund transfer to customer
      (try! (as-contract (contract-call? 'ST1F7QA2MDF17S807EPA36TSS8AMEFY4KA9TVGWXT.sbtc-token
        transfer refund-amount tx-sender customer none
      )))

      ;; Update payment status to refunded
      (map-set payments payment-id
        (merge payment {
          status: "refunded",
          processed-at: (some stacks-block-height),
        })
      )

      (ok refund-amount)
    )
  )
)