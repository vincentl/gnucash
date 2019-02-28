;; -*-scheme-*- ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; balance-forecast.scm
;; Simulate future balance based on scheduled transactions.
;;
;; By Ryan Turner 2019-02-27 <zdbiohazard2@gmail.com>
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2 of
;; the License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, contact:
;;
;; Free Software Foundation           Voice:  +1-617-542-5942
;; 51 Franklin Street, Fifth Floor    Fax:    +1-617-542-2652
;; Boston, MA  02110-1301,  USA       gnu@gnu.org
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-module (gnucash report standard-reports balance-forecast))

(use-modules (gnucash gnc-module))
(use-modules (gnucash gettext))

(gnc:module-load "gnucash/report/report-system" 0)

; Name definitions
(define report-title         (N_ "Balance Forecast"))
(define optname-accounts     (N_ "Accounts"))
(define optname-from-date    (N_ "Simulate from"))
(define optname-to-date      (N_ "Simulate until"))
(define optname-interval     (N_ "Interval"))
(define optname-currency     (N_ "Report currency"))
(define optname-price        (N_ "Price source"))
(define optname-plot-width   (N_ "Plot width"))
(define optname-plot-height  (N_ "Plot height"))
(define optname-show-markers (N_ "Show markers"))
(define optname-show-reserve (N_ "Show reserve line"))
(define optname-reserve      (N_ "Reserve amount"))
(define optname-show-target  (N_ "Show target line"))
(define optname-target       (N_ "Target amount above reserve"))
(define optname-show-minimum (N_ "Show future minimum"))

; Options generator
(define (options-generator)
  (let* ((options (gnc:new-options)))
    ; Account selector
    (gnc:register-option options
      (gnc:make-account-list-option
        gnc:pagename-accounts optname-accounts "a" optname-accounts
        (lambda ()
          (gnc:filter-accountlist-type
            (list ACCT-TYPE-BANK ACCT-TYPE-CASH)
            (gnc-account-get-descendants-sorted
              (gnc-get-current-root-account))))
        #f #t))

    ; Date range
    (gnc:options-add-date-interval! options
      gnc:pagename-general optname-from-date optname-to-date "a")
    ; Date interval
    (gnc:options-add-interval-choice! options
      gnc:pagename-general optname-interval "b" 'DayDelta)
    ; Report currency
    (gnc:options-add-currency! options
      gnc:pagename-general optname-currency "c")
    ; Price source
    (gnc:options-add-price-source! options
      gnc:pagename-general optname-price "d" 'pricedb-nearest)

    ; Plot size
    (gnc:options-add-plot-size! options gnc:pagename-display
      optname-plot-width optname-plot-height "a"
      (cons 'percent 100.0) (cons 'percent 100.0))
    ; Markers
    (gnc:register-option options (gnc:make-simple-boolean-option
      gnc:pagename-display optname-show-markers "b" "" #f))
    ; Reserve line
    (gnc:register-option options (gnc:make-simple-boolean-option
      gnc:pagename-display optname-show-reserve "c" "" #f))
    (gnc:register-option options (gnc:make-number-range-option
      gnc:pagename-display optname-reserve "d" optname-reserve
      0 0 10E9 2 0.01))
    ; Purchasing power target
    (gnc:register-option options (gnc:make-simple-boolean-option
      gnc:pagename-display optname-show-target "e" "" #f))
    (gnc:register-option options (gnc:make-number-range-option
      gnc:pagename-display optname-target "f" optname-target
      0 0 10E9 2 0.01))
    ; Future minimum
    (gnc:register-option options (gnc:make-simple-boolean-option
      gnc:pagename-display optname-show-minimum "g" "" #f))
  options)
)

; Renderer
(define (document-renderer report-obj)
  ; Option-getting helper function.
  (define (get-option pagename optname)
    (gnc:option-value
      (gnc:lookup-option (gnc:report-options report-obj) pagename optname)))

  (gnc:report-starting report-title)

  (let* ( (document (gnc:make-html-document))
          ; Options
          (accounts (get-option gnc:pagename-accounts optname-accounts))

          (from-date (gnc:time64-start-day-time (gnc:date-option-absolute-time
            (get-option gnc:pagename-general optname-from-date))))
          (to-date (gnc:time64-end-day-time (gnc:date-option-absolute-time
            (get-option gnc:pagename-general optname-to-date))))
          (interval (get-option gnc:pagename-general optname-interval))
          (currency (get-option gnc:pagename-general optname-currency))
          (price (get-option gnc:pagename-general optname-price))

          (plot-width (get-option gnc:pagename-display optname-plot-width))
          (plot-height (get-option gnc:pagename-display optname-plot-height))
          (show-markers (get-option gnc:pagename-display optname-show-markers))
          (show-reserve (get-option gnc:pagename-display optname-show-reserve))
          (reserve (get-option gnc:pagename-display optname-reserve))
          (show-target (get-option gnc:pagename-display optname-show-target))
          (target (get-option gnc:pagename-display optname-target))
          (show-minimum (get-option gnc:pagename-display optname-show-minimum))

          ; Variables
          (chart (gnc:make-html-linechart))
          (series (list (list "Balance" "#0A0")))
          (intervals (gnc:make-date-interval-list
            from-date to-date (gnc:deltasym-to-delta interval)))
          (accum (gnc:make-commodity-collector))
          (balances #f)
          (minimum #nil)
        )

    ; Balance line
    (set! balances
      (map (lambda (date) (let* (
          (start-date (car date))
          (end-date (cadr date))
          (balance (gnc:make-commodity-collector))
          (exchange-fn (gnc:case-exchange-fn price currency end-date))
          (sx-value (gnc-sx-all-instantiate-cashflow-all start-date end-date))
         )
        (map (lambda (account)
          (accum 'add (xaccAccountGetCommodity account)
            (hash-ref sx-value (gncAccountGetGUID account) 0))
          (balance 'merge
            (gnc:account-get-comm-balance-at-date account end-date #f) #f)
        ) accounts)
        (balance 'merge accum #f)
        (gnc:gnc-monetary-amount
          (gnc:sum-collector-commodity balance currency exchange-fn))
      )) intervals))
    (gnc:html-linechart-append-column! chart balances)

    ; Future Line
    (if show-minimum (let* ()
      (set! series (append series (list (list "Minimum" "#0AA"))))
      (gnc:html-linechart-append-column! chart
        (reverse (map (lambda (balance)
          (if (null? minimum) (set! minimum balance)
            (if (< balance minimum) (set! minimum balance)))
          minimum) (reverse balances))))))

    ; Target line
    (if show-target (let* ()
      (set! series (append series (list (list "Target" "#FF0"))))
      (gnc:html-linechart-append-column! chart (map (lambda (date)
        (+ target reserve)) intervals))))

    ; Reserve line
    (if show-reserve (let* ()
      (set! series (append series (list (list "Reserve" "#F00"))))
      (gnc:html-linechart-append-column! chart (map (lambda (date)
        reserve) intervals))))

    ; Set the chart titles
    (gnc:html-linechart-set-title! chart report-title)
    (gnc:html-linechart-set-subtitle! chart (format #f (_ "~a to ~a")
      (qof-print-date from-date) (qof-print-date to-date)))
    ; Set the chart size
    (gnc:html-linechart-set-width! chart plot-width)
    (gnc:html-linechart-set-height! chart plot-height)
    ; Set the axis labels
    (gnc:html-linechart-set-y-axis-label! chart
      (gnc-commodity-get-mnemonic currency))
    ; Set line markers
    (gnc:html-linechart-set-markers?! chart show-markers)
    ; Set series labels
    (gnc:html-linechart-set-row-labels! chart
      (map qof-print-date (map car intervals)))
    (gnc:html-linechart-set-col-labels! chart (map car series))
    ; Assign line colors
    (gnc:html-linechart-set-col-colors! chart (map cadr series))

    ; We're done!
    (gnc:html-document-add-object! document chart)
    (gnc:report-finished)
  document))

(gnc:define-report
  'version 1
  'name report-title
  'report-guid "321d940d487d4ccbb4bd0467ffbadbf2"
  'options-generator options-generator
  'renderer document-renderer)