//
//  PaymentViewController.swift
//  NISdk
//
//  Created by Johnny Peter on 19/08/19.
//  Copyright © 2019 Network International. All rights reserved.
//

import Foundation
import PassKit

typealias MakePaymentCallback = (PaymentRequest) -> Void

typealias AaniPaymentCallback = () -> Void

typealias MakeSaveCardPaymentCallback = (SavedCardRequest) -> Void

class PaymentViewController: UIViewController {
    private var state: State?
    private weak var shownViewController: UIViewController?
    
    private let transactionService = TransactionServiceAdapter()
    private weak var cardPaymentDelegate: CardPaymentDelegate?
    private let order: OrderResponse
    private var paymentResponse: PaymentResponse?
    private var paymentToken: String?
    private var accessToken: String?
    private let paymentMedium: PaymentMedium
    private var applePayController: ApplePayController?
    private var applePayDelegate: ApplePayDelegate?
    var applePayRequest: PKPaymentRequest?
    private let cvv: String?
    private var host: String?
    private var backLink: String? = nil
    
    init(order: OrderResponse, cardPaymentDelegate: CardPaymentDelegate,
         applePayDelegate: ApplePayDelegate?, paymentMedium: PaymentMedium, backLink: String = "") {
        self.order = order
        self.cardPaymentDelegate = cardPaymentDelegate
        self.paymentMedium = paymentMedium
        if let applePayDelegate = applePayDelegate {
            self.applePayDelegate = applePayDelegate
        }
        self.cvv = nil
        self.backLink = backLink
        super.init(nibName: nil, bundle: nil)
    }
    
    init(paymentResponse: PaymentResponse, cardPaymentDelegate: CardPaymentDelegate) {
        self.order = OrderResponse()
        self.paymentMedium = .ThreeDSTwo
        self.cardPaymentDelegate = cardPaymentDelegate
        self.paymentResponse = paymentResponse
        self.cvv = nil
        super.init(nibName: nil, bundle: nil)
    }
    
    init(order: OrderResponse,
         cardPaymentDelegate: CardPaymentDelegate,
         applePayDelegate: ApplePayDelegate?,
         paymentMedium: PaymentMedium,
         cvv: String?
    ) {
        self.order = order
        self.cardPaymentDelegate = cardPaymentDelegate
        self.paymentMedium = paymentMedium
        if let applePayDelegate = applePayDelegate {
            self.applePayDelegate = applePayDelegate
        }
        self.cvv = cvv
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        print("orderRef \(self.order.reference ?? "")")
        self.performPreAuthChecksAndBeginAuth()
    }
    
    // Perform any checks that need to be done before auth
    private func performPreAuthChecksAndBeginAuth() {
        if(self.paymentMedium == .ThreeDSTwo ) {
            guard let authenticationCode = self.paymentResponse?.authenticationCode else {
                self.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: .ThreeDSFailed, and: .AuthFailed);
                return
            }
            
            guard let threeDSTwoAuthenticationURL = self.paymentResponse?.paymentLinks?.paymentLink else {
                self.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: .ThreeDSFailed, and: .AuthFailed);
                return
            }
            
            let authUrl = URL(string: threeDSTwoAuthenticationURL)
            
            guard let authUrlHost = authUrl?.host,
                    let outletId = paymentResponse?.outletId,
                    let orderReference = paymentResponse?.orderReference else {
                self.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: .ThreeDSFailed, and: .AuthFailed);
                return
            }
            self.order.orderLinks = OrderLinks(paymentLink: "",
                                               paymentAuthorizationLink: "",
                                               orderLink: "https://\(authUrlHost)/transactions/outlets/\(outletId)/orders/\(orderReference)",
                                               payPageLink: "")
            self.execThreeDSTwo(using: authenticationCode, domain: authUrlHost)
            return
        }
        
        // Apple pay is not enabled by merchant, hence abort payment flow
        if(self.paymentMedium == .ApplePay && (self.order.embeddedData?.payment?[0].paymentLinks?.applePayLink) == nil) {
            self.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: .ThreeDSFailed, and: .AuthFailed);
            return
        }
        // 1. Perform authorization by aquiring a payment token
        self.authorizePayment()
    }
    
    private func execThreeDSTwo(using code: String, domain: String) {
        let authUrl = "https://\(domain)/transactions/paymentAuthorization"
        transactionService.authorizePayment(for: code, using: authUrl, on: {
            [weak self] tokens in
            if let paymentToken = tokens["payment-token"], let accessToken = tokens["access-token"] {
                self?.paymentToken = paymentToken
                self?.accessToken = accessToken
                DispatchQueue.main.async { // Use the main thread to update any UI
                    self?.initiatePaymentForm()
                }
            } else {
                self?.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: nil, and: .AuthFailed)
            }
        })
        
    }
    
    private func authorizePayment() {
        cardPaymentDelegate?.authorizationDidBegin?()
        self.transition(to: .authorizing)
        if let authCode = order.getAuthCode(),
           let paymentLink = order.orderLinks?.paymentAuthorizationLink {
            transactionService.authorizePayment(for: authCode, using: paymentLink, on: {
                [weak self] tokens in
                if let paymentToken = tokens["payment-token"], let accessToken = tokens["access-token"] {
                    // Callback hell...
                    self?.paymentToken = paymentToken
                    self?.accessToken = accessToken
                    // 2. Show card payment screen after authorization (payment token is received)
                    DispatchQueue.main.async { // Use the main thread to update any UI
                        self?.cardPaymentDelegate?.authorizationDidComplete?(with: .AuthSuccess)
                        self?.cardPaymentDelegate?.paymentDidBegin?()
                        self?.initiatePaymentForm()
                    }
                } else {
                    self?.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: nil, and: .AuthFailed)
                }
            })
        } else {
            // Close payment view controller if authCode or payment link is broken
            self.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: nil, and: .AuthFailed)
        }
    }
    
    private func initiatePaymentForm() {
        switch paymentMedium {
        case .Card:
            let cardPaymentViewController = CardPaymentViewController(makePaymentCallback: self.makePayment, aaniPaymentCallback: self.aaniPayment, order: order, onCancel: {
                [weak self] in
                if NISdk.sharedInstance.shouldShowCancelAlert {
                    self?.showCancelPaymentAlert(with: .PaymentCancelled, and: nil, and: nil)
                } else {
                    self?.finishPaymentAndClosePaymentViewController(with: .PaymentCancelled, and: nil, and: nil)
                }
            })
            self.transition(to: .renderCardPaymentForm(cardPaymentViewController))
            break
        case .ApplePay:
            if let applePayRequest = applePayRequest {
                applePayController = ApplePayController(applePayDelegate: self.applePayDelegate!,
                                                        order: order,
                                                        onDismissCallback: handlePaymentResponse,
                                                        onAuthorizeApplePayCallback: handleApplePayAuthorization)
                let cards = order.paymentMethods?.card ?? []
                let cardProviders = cards.compactMap { CardProvider(rawValue: $0) }
                let allowedPKPaymentNetworks = cardProviders.map({ $0.pkNetworkType })
                applePayRequest.supportedNetworks = Array(Set(allowedPKPaymentNetworks))
                // Dont use container view controllers for apple pay
                let pkPaymentAuthorizationVC = PKPaymentAuthorizationViewController(paymentRequest: applePayRequest)
                if let pkPaymentAuthorizationVC = pkPaymentAuthorizationVC {
                    pkPaymentAuthorizationVC.delegate = applePayController
                    self.shownViewController?.remove()
                    self.present(pkPaymentAuthorizationVC, animated: false, completion: nil)
                    return
                }
            }
            self.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: nil, and: nil)
            break
        case .ThreeDSTwo:
            self.handlePaymentResponse(self.paymentResponse)
            break
        case .SavedCard:
            if let savedCard = order.savedCard, let amount = order.amount {
                if savedCard.recaptureCsc {
                    let savedCardViewController = SavedCardViewController(
                        makeSaveCardPaymentCallback: self.makeSavedCardPayment,
                        savedCard: savedCard,
                        orderAmount: amount,
                        onCancel: {
                            [weak self] in
                            if NISdk.sharedInstance.shouldShowCancelAlert {
                                self?.showCancelPaymentAlert(with: .PaymentCancelled, and: nil, and: nil)
                            } else {
                                self?.finishPaymentAndClosePaymentViewController(with: .PaymentCancelled, and: nil, and: nil)
                            }
                        })
                    self.transition(to: .renderCardPaymentForm(savedCardViewController))
                } else {
                    makeSavedCardPayment(
                        SavedCardRequest(
                            expiry: savedCard.expiry,
                            cardholderName: savedCard.cardholderName,
                            cardToken: savedCard.cardToken,
                            cvv: nil))
                }
            } else {
                finishPaymentAndClosePaymentViewController(with: .InValidRequest, and: nil, and: .AuthFailed)
            }
            break
        }
    }
    
    lazy private var handleApplePayAuthorization: OnAuthorizeApplePayCallback  = {
        [unowned self] payment, completion in
        self.getPayerIp() { (payerIp) -> () in
            if let payment = payment, let completion = completion {
                self.transactionService.postApplePayResponse(for: self.order,
                                                             with: payment,
                                                             using: self.accessToken!,
                                                             payerIp: payerIp, on: {
                    [unowned self] data, response, error in
                    if let data = data {
                        do {
                            let paymentResponse: PaymentResponse = try JSONDecoder().decode(PaymentResponse.self, from: data)
                            if(paymentResponse.state == "AUTHORISED" || paymentResponse.state == "CAPTURED" || paymentResponse.state == "PURCHASED" || paymentResponse.state == "VERIFIED" || paymentResponse.state == "POST_AUTH_REVIEW") {
                                completion(PKPaymentAuthorizationResult(status: .success, errors: nil), paymentResponse)
                            } else {
                                completion(PKPaymentAuthorizationResult(status: .failure, errors: nil), paymentResponse)
                            }
                        } catch let error {
                            completion(PKPaymentAuthorizationResult(status: .failure, errors: nil), nil)
                        }
                    }
                })
            } else {
                self.handlePaymentResponse(nil)
            }
        }
    }
    
    lazy private var aaniPayment = {
        if let accessToken = self.accessToken,
           let backLink = self.backLink,
           let aaniPayArgs = self.order.toAaniPayArgs(backLink, accessToken: accessToken) {
            let aaniPayViewController = AaniPayViewController(aaniPayArgs: aaniPayArgs) { status in
                switch status {
                case .success:
                    self.finishPaymentAndClosePaymentViewController(with: .PaymentSuccess, and: nil, and: nil)
                case .failed:
                    self.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: nil, and: nil)
                case .cancelled:
                    self.finishPaymentAndClosePaymentViewController(with: .PaymentCancelled, and: nil, and: nil)
                case .invalidRequest:
                    self.finishPaymentAndClosePaymentViewController(with: .InValidRequest, and: nil, and: nil)
                }
            }
            self.transition(to: .renderCardPaymentForm(aaniPayViewController))
        }
    }
    
    lazy private var makePayment = { (paymentRequest: PaymentRequest) in
        // 3. Make Payment
        self.getPayerIp() { (payerIp) -> () in
            paymentRequest.payerIp = payerIp
            
            self.getVisaPlans(visaEligibilityRequets: VisaEligibilityRequets(cardToken: nil, pan: paymentRequest.pan), onResponse: { visaPlan in
                if let plans = visaPlan, let fullAmount = self.order.amount, let cardNumber = paymentRequest.pan {
                    if (plans.matchedPlans.isEmpty) {
                        self.makeCardPayment(paymentRequest: paymentRequest)
                    } else {
                        DispatchQueue.main.async {
                            self.transition(to: .renderCardPaymentForm(VisaInstallmentViewController(visaPlan: plans, fullAmount: fullAmount, cardNumber: cardNumber, onMakePayment: { visaRequest in
                                paymentRequest.visaRequest = visaRequest
                                self.makeCardPayment(paymentRequest: paymentRequest)
                            }, onCancel: {
                                [weak self] in
                                if NISdk.sharedInstance.shouldShowCancelAlert {
                                    self?.showCancelPaymentAlert(with: .PaymentCancelled, and: nil, and: nil)
                                } else {
                                    self?.finishPaymentAndClosePaymentViewController(with: .PaymentCancelled, and: nil, and: nil)
                                }
                            })))
                        }
                    }
                } else {
                    self.makeCardPayment(paymentRequest: paymentRequest)
                }
            })
        }
    }
    
    private func makeCardPayment(paymentRequest: PaymentRequest) {
        self.transactionService.makePayment(for: self.order, with: paymentRequest, using: self.paymentToken!, on: {
            data, response, err in
            if err != nil {
                self.handlePaymentResponse(nil)
            } else if let data = data {
                do {
                    let paymentResponse: PaymentResponse = try JSONDecoder().decode(PaymentResponse.self, from: data)
                    // 4. Intermediatory checks for payment failure attempts and anything else
                    self.handlePaymentResponse(paymentResponse)
                } catch _ {
                    self.handlePaymentResponse(nil)
                }
            }
        })
    }
    
    lazy private var makeSavedCardPayment = { (savedCardRequest: SavedCardRequest) in
        // 3. Make Payment
        self.getPayerIp() { (payerIp) -> () in
            savedCardRequest.payerIp = payerIp
            
            if let savedCardUrl = self.order.embeddedData?.getSavedCardLink(), let accessToken = self.accessToken, let cardToken = self.order.savedCard?.cardToken, let cardNumber = self.order.savedCard?.maskedPan {
                if let matchedCandidates: [MatchedCandidate] = self.order.visSavedCardMatchedCandidates?.matchedCandidates, let candidate = matchedCandidates.first(where: { $0.cardToken == cardToken }) {
                    if candidate.eligibilityStatus == "MATCHED" {
                        self.getVisaPlans(visaEligibilityRequets: VisaEligibilityRequets(cardToken: cardToken, pan: nil), onResponse: { visaPlan in
                            if let plans = visaPlan, let fullAmount = self.order.amount {
                                if (plans.matchedPlans.isEmpty) {
                                    self.doSavedCardPayment(savedCardUrl: savedCardUrl, savedCardRequest: savedCardRequest, accessToken: accessToken)
                                } else {
                                    DispatchQueue.main.async {
                                        self.transition(to: .renderCardPaymentForm(VisaInstallmentViewController(visaPlan: plans, fullAmount: fullAmount, cardNumber: cardNumber, onMakePayment: { visaRequest in
                                            savedCardRequest.visaRequest = visaRequest
                                            self.doSavedCardPayment(savedCardUrl: savedCardUrl, savedCardRequest: savedCardRequest, accessToken: accessToken)
                                        }, onCancel: {
                                            [weak self] in
                                            if NISdk.sharedInstance.shouldShowCancelAlert {
                                                self?.showCancelPaymentAlert(with: .PaymentCancelled, and: nil, and: nil)
                                            } else {
                                                self?.finishPaymentAndClosePaymentViewController(with: .PaymentCancelled, and: nil, and: nil)
                                            }
                                        })))
                                    }
                                }
                            } else {
                                self.doSavedCardPayment(savedCardUrl: savedCardUrl, savedCardRequest: savedCardRequest, accessToken: accessToken)
                            }
                        })
                    } else {
                        self.doSavedCardPayment(savedCardUrl: savedCardUrl, savedCardRequest: savedCardRequest, accessToken: accessToken)
                    }
                } else {
                    self.doSavedCardPayment(savedCardUrl: savedCardUrl, savedCardRequest: savedCardRequest, accessToken: accessToken)
                }
            }
        }
    }
    
    private func doSavedCardPayment(savedCardUrl: String, savedCardRequest: SavedCardRequest, accessToken: String) {
        self.transactionService.doSavedCardPayment(
            for: savedCardUrl,
            with: savedCardRequest,
            using: accessToken,
            on: {
                data, response, error in
                if error != nil {
                    self.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: nil, and: nil)
                } else if let data = data {
                    do {
                        let paymentResponse: PaymentResponse = try JSONDecoder().decode(PaymentResponse.self, from: data)
                        self.handlePaymentResponse(paymentResponse)
                    } catch _ {
                        self.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: nil, and: nil)
                    }
                }
            })
    }
    
    func getPayerIp(onCompletion: @escaping (String?) -> ()) {
        guard let url = order.orderLinks?.payPageLink, let urlHost = URL(string: url)?.host else {
            onCompletion(nil)
            return
        }
        let ipUrl = "https://\(urlHost)/api/requester-ip"
        self.transactionService.getPayerIp(with: ipUrl, on: { payerIPData, _, _ in
            if let payerIPData = payerIPData {
                do {
                    let payerIpDict: [String: String] = try JSONDecoder().decode([String: String].self, from: payerIPData)
                    onCompletion(payerIpDict["requesterIp"])
                } catch {
                    onCompletion(nil)
                }
            } else {
                onCompletion(nil)
            }
        })
    }
    
    lazy private var handlePaymentResponse: (PaymentResponse?) -> Void = {
        paymentResponse in
        DispatchQueue.main.async {
            guard let paymentResponse = paymentResponse else {
                self.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: nil, and: nil)
                return
            }
            if(paymentResponse.state == "AUTHORISED" || paymentResponse.state == "CAPTURED" || paymentResponse.state == "PURCHASED" || paymentResponse.state == "VERIFIED") {
                // 5. Close Screen if payment is done
                self.finishPaymentAndClosePaymentViewController(with: .PaymentSuccess, and: nil, and: nil)
                return
            }
            if (paymentResponse.state == "POST_AUTH_REVIEW") {
                self.finishPaymentAndClosePaymentViewController(with: .PaymentPostAuthReview, and: nil, and: nil)
                return
            }
            if(paymentResponse.state == "AWAIT_3DS") {
                self.cardPaymentDelegate?.threeDSChallengeDidBegin?()
                self.initiateThreeDS(with: paymentResponse)
                return
            }
            if (paymentResponse.state == "AWAITING_PARTIAL_AUTH_APPROVAL") {
                self.cardPaymentDelegate?.partialAuthBegin?()
                do {
                    let partialAuthArgs = try paymentResponse.toPartialAuthArgs(accessToken: self.accessToken)
                    self.initiatePartialAuth(partialAuthArgs: partialAuthArgs)
                } catch {
                    self.cardPaymentDelegate?.paymentDidComplete(with: .InValidRequest)
                }
                return
            }
            self.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: nil, and: nil)
        }
    }
    
    private func initiatePartialAuth(partialAuthArgs: PartialAuthArgs) {
        self.transition(to: .renderCardPaymentForm(
            PartialAuthViewController(
                partialAuthArgs: partialAuthArgs,
                onSuccess: {
                    self.finishPaymentAndClosePaymentViewController(with: .PaymentSuccess, and: nil, and: nil)
                },
                onFailed: {
                    self.finishPaymentAndClosePaymentViewController(with: .PartialAuthDeclineFailed, and: nil, and: nil)
                },
                onDecline: {
                    self.finishPaymentAndClosePaymentViewController(with: .PartialAuthDeclined, and: nil, and: nil)
                },
                onPartialAuth:  {
                    self.finishPaymentAndClosePaymentViewController(with: .PartiallyAuthorised, and: nil, and: nil)
                }
            )
        ))
    }
    
    private func initiateThreeDS(with paymentRepsonse: PaymentResponse) {
        if let acsUrl = paymentRepsonse.threeDSConfig?.acsUrl,
           let acsPaReq = paymentRepsonse.threeDSConfig?.acsPaReq,
           let acsMd = paymentRepsonse.threeDSConfig?.acsMd,
           let threeDSTermURL = paymentRepsonse.paymentLinks?.threeDSTermURL {
            let threeDSViewController = ThreeDSViewController(with: acsUrl,
                                                              acsPaReq: acsPaReq,
                                                              acsMd: acsMd,
                                                              threeDSTermURL: threeDSTermURL,
                                                              completion: onThreeDSCompletion)
            self.transition(to: .renderThreeDSChallengeForm(threeDSViewController))
        } else if let accessToken = self.accessToken {
            // Start threeds two
            let threeDSTwoViewController = ThreeDSTwoViewController(with: paymentRepsonse,
                                                                    accessToken: accessToken,
                                                                    transactionService: self.transactionService,
                                                                    completion: onThreeDSCompletion)
            self.transition(to: .renderThreeDSChallengeForm(threeDSTwoViewController))
        } else {
            self.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: .ThreeDSFailed, and: nil)
        }
    }
    
    lazy private var onThreeDSCompletion: (Bool) -> Void = { [weak self] hasSDKError in
        if(hasSDKError) {
            self?.handlePaymentResponse(nil)
            return
        }
        self?.transactionService.getOrder(for: (self?.order.orderLinks?.orderLink)!, using: self!.accessToken!, with:
                                                { (data, response, error) in
            if let data = data {
                do {
                    let orderResponse: OrderResponse = try JSONDecoder().decode(OrderResponse.self, from: data)
                    if let state = orderResponse.embeddedData?.payment?.first?.state {
                        if state == "AWAITING_PARTIAL_AUTH_APPROVAL" {
                            DispatchQueue.main.async {
                                do {
                                    self?.initiatePartialAuth(partialAuthArgs: try orderResponse.toPartialAuthArgs(accessToken: self?.accessToken))
                                } catch {
                                    self?.finishPaymentAndClosePaymentViewController(with: .PaymentFailed, and: nil, and: nil)
                                }
                            }
                            return
                        }
                    }
                    var successfulPayments: [PaymentResponse] = []
                    var awaitThreedsPayments: [PaymentResponse] = []
                    if let paymentResponses = orderResponse.embeddedData?.payment {
                        successfulPayments = paymentResponses.filter({ (paymentAttempt: PaymentResponse) -> Bool in
                            return paymentAttempt.state == "CAPTURED" || paymentAttempt.state == "AUTHORISED" || paymentAttempt.state == "PURCHASED" || paymentAttempt.state == "VERIFIED" || paymentAttempt.state == "POST_AUTH_REVIEW"
                        })
                        
                        awaitThreedsPayments = paymentResponses.filter({ (paymentAttempt: PaymentResponse) -> Bool in
                            return paymentAttempt.state == "AWAIT_3DS"
                        })
                    }
                    
                    if(successfulPayments.count > 0) {
                        self?.handlePaymentResponse(successfulPayments[0])
                    } else if(awaitThreedsPayments.count > 0) {
                        // we are still waiting for 3ds to complete
                        return
                    } else {
                        self?.handlePaymentResponse(nil)
                    }
                } catch let error {
                    self?.handlePaymentResponse(nil)
                }
            }
        })
    }
    
    // This is called when payment is done(fail or success) with 3ds(fail or success) or without 3ds
    private func finishPaymentAndClosePaymentViewController(with paymentStatus: PaymentStatus,
                                                            and threeDSStatus: ThreeDSStatus?,
                                                            and authStatus: AuthorizationStatus?) {
        DispatchQueue.main.async { // Use the main thread to update any UI
            if let threeDSStatus = threeDSStatus {
                self.cardPaymentDelegate?.threeDSChallengeDidComplete?(with: threeDSStatus)
            }
            
            if let authStatus = authStatus  {
                self.cardPaymentDelegate?.authorizationDidComplete?(with: authStatus)
            }
            
            self.closePaymentViewController(completion: {
                [weak self] in
                self?.cardPaymentDelegate?.paymentDidComplete(with: paymentStatus)
            })
        }
    }
    
    private func closePaymentViewController(completion: (() -> Void)?) {
        dismiss(animated: true, completion: completion)
    }
}

private extension PaymentViewController {
    enum State {
        case authorizing
        case renderCardPaymentForm(UIViewController)
        case renderThreeDSChallengeForm(UIViewController)
    }
    
    private func transition(to newState: State) {
        shownViewController?.remove()
        let vc = viewController(for: newState)
        add(vc, inside: view)
        shownViewController = vc
        state = newState
    }
    
    func viewController(for state: State) -> UIViewController {
        switch state {
        case .authorizing:
            return AuthorizationViewController()
            
        case .renderCardPaymentForm(let viewController),
                .renderThreeDSChallengeForm(let viewController):
            return viewController
        }
    }
}

private extension PaymentViewController {
    private func showCancelPaymentAlert(with paymentStatus: PaymentStatus,
                                        and threeDSStatus: ThreeDSStatus?,
                                        and authStatus: AuthorizationStatus?) {
        let alertController = UIAlertController(
            title: "Cancel Payment Title".localized,
            message: "Cancel Payment Message".localized,
            preferredStyle: .alert
        )
        
        alertController.addAction(UIAlertAction(title: "Cancel Alert".localized, style: .cancel))
        alertController.addAction(UIAlertAction(title: "Cancel Confirm".localized, style: .destructive) { _ in
            self.finishPaymentAndClosePaymentViewController(with: paymentStatus, and: threeDSStatus, and: authStatus)
            self.dismiss(animated: true, completion: nil)
        })
        
        present(alertController, animated: true, completion: nil)
    }
}

private extension PaymentViewController {
    func getVisaPlans(visaEligibilityRequets: VisaEligibilityRequets, onResponse: @escaping (VisaPlans?) -> Void) {
        if let selfLink = self.order.embeddedData?.getSelfLink(), let accessToken = self.accessToken {
            self.transactionService.getVisaPlans(
                with: selfLink,
                using: accessToken,
                cardToken: visaEligibilityRequets.cardToken,
                cardNumber: visaEligibilityRequets.pan,
                on: { data, response, err in
                    if err != nil {
                        onResponse(nil)
                    } else if let data = data {
                        do {
                            let visaPlans: VisaPlans = try JSONDecoder().decode(VisaPlans.self, from: data)
                            onResponse(visaPlans)
                        } catch _ {
                            onResponse(nil)
                        }
                    }
                })
        } else {
            onResponse(nil)
        }
    }
}
