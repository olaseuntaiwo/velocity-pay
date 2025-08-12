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