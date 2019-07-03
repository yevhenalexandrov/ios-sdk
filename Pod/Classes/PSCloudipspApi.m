//
//  PSCloudipspApi.m
//  Cloudipsp
//
//  Created by Nadiia Dovbysh on 1/24/16.
//  Copyright © 2016 Сloudipsp. All rights reserved.
//

#import "PSPayConfirmation.h"
#import "PSCloudipspApi.h"
#import "PSLocalization.h"
#import "PSUtils.h"

#import "Models/PSCard.h"
#import "Models/PSCurrency.h"
#import "Models/PSReceipt.h"
#import "Models/PSOrder.h"

#import <PassKit/PassKit.h>


#pragma mark - PSPayCallbackDelegateMainWrapper

@interface PSPayCallbackDelegateMainWrapper : NSObject<PSPayCallbackDelegate>

+ (instancetype)wrapperWithOrigin:(id<PSPayCallbackDelegate>)origin;

@property (nonatomic, strong) id<PSPayCallbackDelegate> origin;

@end

@implementation PSPayCallbackDelegateMainWrapper

+ (instancetype)wrapperWithOrigin:(id<PSPayCallbackDelegate>)origin {
    PSPayCallbackDelegateMainWrapper *wrapper = [[PSPayCallbackDelegateMainWrapper alloc] init];
    
    wrapper.origin = origin;
    
    return wrapper;
}

- (void)onPaidProcess:(PSReceipt *)receipt {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.origin onPaidProcess:receipt];
    });
}

- (void)onPaidFailure:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.origin onPaidFailure:error];
    });
}

- (void)onWaitConfirm {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.origin onWaitConfirm];
    });
}

@end



#pragma mark - PSPayCallbackDelegateApplePayWrapper

API_AVAILABLE(ios(11.0))
@interface PSPayCallbackDelegateApplePayWrapper : NSObject<PSPayCallbackDelegate>
    
+ (instancetype)wrapperWithOrigin:(id<PSPayCallbackDelegate>)origin
              andApplePayCallback:(void (^)(PKPaymentAuthorizationResult *))applePayCallback;
    
@property (nonatomic, strong) id<PSPayCallbackDelegate> origin;
@property (nonatomic, strong) void (^applePayCallback)(PKPaymentAuthorizationResult *);
    
@end

@implementation PSPayCallbackDelegateApplePayWrapper
    
+ (instancetype)wrapperWithOrigin:(id<PSPayCallbackDelegate>)origin
              andApplePayCallback:(void (^)(PKPaymentAuthorizationResult *))applePayCallback {
    PSPayCallbackDelegateApplePayWrapper *wrapper = [[PSPayCallbackDelegateApplePayWrapper alloc] init];
    
    wrapper.origin = origin;
    wrapper.applePayCallback = applePayCallback;
    
    return wrapper;
}
    
- (void)onPaidProcess:(PSReceipt *)receipt {
    [self.origin onPaidProcess:receipt];
    if (receipt.status == PSReceiptStatusDeclined) {
        self.applePayCallback([[PKPaymentAuthorizationResult alloc] initWithStatus:PKPaymentAuthorizationStatusFailure errors:nil]);
    } else {
        self.applePayCallback([[PKPaymentAuthorizationResult alloc] initWithStatus:PKPaymentAuthorizationStatusSuccess errors:nil]);
    }
}
    
- (void)onPaidFailure:(NSError *)error {
    [self.origin onPaidFailure:error];

    self.applePayCallback([[PKPaymentAuthorizationResult alloc] initWithStatus:PKPaymentAuthorizationStatusFailure errors:@[error]]);
}
    
- (void)onWaitConfirm {
    [self.origin onWaitConfirm];
}
    
@end

#pragma mark - PSSendData

@interface PSSendData : NSObject

@property (nonatomic, strong) NSString *md;
@property (nonatomic, strong) NSString *paReq;
@property (nonatomic, strong) NSString *termUrl;

@end

@implementation PSSendData

- (instancetype)initSendData:(NSString *)md aPaReq:(NSString *)paReq aTermUrl:(NSString *)termUrl
{
    self = [super init];
    if (self) {
        self.md = md;
        self.paReq = paReq;
        self.termUrl = termUrl;
    }
    return self;
}

@end

#pragma mark - PSCheckout

const NSInteger WITHOUT_3DS = 0;
const NSInteger WITH_3DS = 1;

@interface PSCheckout : NSObject

@property (nonatomic, strong) PSSendData *sendData;
@property (nonatomic, strong) NSString *url;
@property (nonatomic, assign) NSInteger action;

@end

@implementation PSCheckout

- (instancetype)initCheckout:(PSSendData *)sendData aUrl:(NSString *)url aAction:(NSInteger)action
{
    self = [super init];
    if (self) {
        self.sendData = sendData;
        self.url = url;
        self.action = action;
    }
    return self;
}

@end

#pragma mark - PSCard

@interface PSCard (private)

@property (nonatomic, strong, readonly) NSString *cardNumber;

@end

#pragma mark - PSReceipt

@interface PSReceipt (private)

- (instancetype)initReceipt:(NSDictionary *)response
                  aMaskCard:(NSString *)maskedCard
                   aCardBin:(NSInteger)cardBin
                    aAmount:(NSInteger)amount
                 aPaymentId:(NSInteger)paymentId
                  acurrency:(NSString *)currency
                    aStatus:(PSReceiptStatus)status
            aTransationType:(PSReceiptTransationType)transationType
           aSenderCellPhone:(NSString *)senderCellPhone
             aSenderAccount:(NSString *)senderAccount
                  aCardType:(PSCardType)cardType
                       aRrn:(NSString *)rrn
              aApprovalCode:(NSString *)approvalCode
              aResponseCode:(NSString *)responseCode
                 aProductId:(NSString *)productId
                  aRecToken:(NSString *)recToken
          aRecTokenLifeTime:(NSDate *)recTokenLifeTime
            aReversalAmount:(NSInteger)reversalAmount
          aSettlementAmount:(NSInteger)settlementAmount
        aSettlementCurrency:(NSString *)settlementCurrency
            aSettlementDate:(NSDate *)settlementDate
                       aEci:(NSInteger)eci
                       aFee:(NSInteger)fee
              aActualAmount:(NSInteger)actualAmount
            aActualCurrency:(NSString *)actualCurrency
             aPaymentSystem:(NSString *)paymentSystem
        aVerificationStatus:(PSReceiptVerificationStatus)verificationStatus
                 aSignature:(NSString *)signature;

@end

NSString * const HOST = @"https://api.fondy.eu";
NSString * const URL_CALLBACK = @"http://callback";
NSString * const DATE_AND_TIME_FORMAT = @"dd.MM.yyyy HH:mm:ss";
NSString * const DATE_FORMAT = @"dd.MM.yyyy";

PSLocalization *_localization;

@interface PSCloudipspApi () <NSURLSessionDelegate, PKPaymentAuthorizationViewControllerDelegate>

@property (nonatomic, assign) NSInteger merchantId;
@property (nonatomic, strong) PSOrder *applePayOrder;
@property (nonatomic, strong) id<PSPayCallbackDelegate> applePayPayCallbackDelegate;
@property (nonatomic, weak) id<PSCloudipspView> cloudipspView;

@end

@implementation PSCloudipspApi

+ (BOOL)supportsApplePay {
    return [PKPaymentAuthorizationViewController canMakePayments];
}

+ (instancetype)apiWithMerchant:(NSInteger)merchantId andCloudipspView:(id<PSCloudipspView>)cloudipspView;
{
    PSCloudipspApi *api = [[PSCloudipspApi alloc] init];
    api.merchantId = merchantId;
    api.cloudipspView = cloudipspView;
    return api;
}

- (void)call:(NSString *)path
     aParams:(NSDictionary *)params
   onSuccess:(void (^)(NSDictionary *response))success
 payDelegate:(id<PSPayCallbackDelegate>)delegate {
    [self callByUrl:[NSURL URLWithString:[NSString stringWithFormat: @"%@%@", HOST, path]] aParams:@{@"request" : params} onSuccess:^(NSData *data) {
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        success([self parseResponse: json]);
    } payDelegate:delegate];
}

- (void)callByUrl:(NSURL *)url
          aParams:(NSDictionary *)params
        onSuccess:(void (^)(NSData *data))success
      payDelegate:(id<PSPayCallbackDelegate>)delegate {
    [self callByUrl:url aParams:params onSuccess:success payDelegate:delegate onIntercept:^(NSMutableURLRequest *request) {
        [request addValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setHTTPMethod:@"POST"];
        
        NSData *body = [NSJSONSerialization dataWithJSONObject:params options:0 error:nil];
        [request setHTTPBody:body];
    }];
}

- (void)callByUrl:(NSURL *)url
          aParams:(NSDictionary *)params
        onSuccess:(void (^)(NSData *data))success
      payDelegate:(id<PSPayCallbackDelegate>)delegate
      onIntercept:(void (^)(NSMutableURLRequest *request))interceptor {
    
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    interceptor(request);
    
    NSURLSessionDataTask *postDataTask = [session dataTaskWithRequest:request
                                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error)
                                          {
                                              if (error) {
                                                  error = [NSError errorWithDomain:@"CloudipspApi" code:PSPayErrorCodeNetworkAccess userInfo:nil];
                                                  [delegate onPaidFailure:error];
                                              } else {
                                                  @try {
                                                      success(data);
                                                  }
                                                  @catch (NSException *exception) {
                                                      NSError *error;
                                                      if (exception.userInfo == nil) {
                                                          error = [NSError errorWithDomain:@"CloudipspApi" code:PSPayErrorCodeUnknown userInfo:nil];
                                                      } else {
                                                          error = [NSError errorWithDomain:@"CloudipspApi" code:PSPayErrorCodeFailure userInfo:exception.userInfo];
                                                      }
                                                      [delegate onPaidFailure:error];
                                                      
                                                  }
                                              }}];
    
    [postDataTask resume];
}

- (NSDictionary *)parseResponse:(NSDictionary *)response {
    @try {
        NSDictionary *dict = [response objectForKey:@"response"];
        [self checkResponse:dict];
        return dict;
    }
    @catch (NSException *exception) {
        @throw [NSException exceptionWithName:@"RuntimeException" reason:exception.reason userInfo:exception.userInfo];
    }
}

- (void)checkResponse:(NSDictionary *)response {
    NSString *str = [response objectForKey:@"response_status"];
    if (str != nil && ![str isEqualToString:@"success"]) {
        NSString *reason = [NSString stringWithFormat:@"%@, %@",[response objectForKey:@"error_message"], [response objectForKey:@"error_code"]];
        NSDictionary *userInfo = @{@"error_code" : [response objectForKey:@"error_code"],
                                   @"error_message" : [response objectForKey:@"error_message"],
                                   @"request_id" : [response objectForKey:@"request_id"],
                                   @"response_status" : [response objectForKey:@"response_status"]};
        @throw [NSException exceptionWithName: @"PSIllegalResponseException" reason: reason userInfo: userInfo];
    }
}

- (void)getToken:(PSOrder *)order
       onSuccess:(void (^)(NSString *token))success
     payDelegate:(id<PSPayCallbackDelegate>)delegate {
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithDictionary:
                                       @{
                                         @"order_id" : order.identifier,
                                         @"merchant_id" : [NSString stringWithFormat:@"%ld", (long)self.merchantId],
                                         @"order_desc" : order.about,
                                         @"delayed" : @"n",
                                         @"amount" : [NSString stringWithFormat:@"%ld", (long)order.amount],
                                         @"currency" : order.currency,
                                         @"merchant_data" : @"[]"
                                         }];
    
    if (![PSUtils isEmpty:order.productId]) {
        [dictionary setObject:order.productId forKey:@"product_id"];
    }
    if (![PSUtils isEmpty:order.paymentSystems]) {
        [dictionary setObject:order.paymentSystems forKey:@"payment_systems"];
    }
    if (![PSUtils isEmpty:order.defaultPaymentSystem]) {
        [dictionary setObject:order.defaultPaymentSystem forKey:@"default_payment_system"];
    }
    if (order.lifetime != -1) {
        [dictionary setObject:[NSNumber numberWithInteger:order.lifetime] forKey:@"lifetime"];
    }
    if (![PSUtils isEmpty:order.merchantData]) {
        [dictionary setObject:order.merchantData forKey:@"merchant_data"];
    }
    if (![PSUtils isEmpty:order.version]) {
        [dictionary setObject:order.version forKey:@"version"];
    }
    if (![PSUtils isEmpty:order.serverCallbackUrl]) {
        [dictionary setObject:order.serverCallbackUrl forKey:@"server_callback_url"];
    }
    
    if (![PSUtils isEmpty:order.reservationData]) {
        [dictionary setObject:order.reservationData forKey:@"reservation_data"];
    }
    
    if (order.lang != 0) {
        [dictionary setObject:[PSOrder getLangName:order.lang] forKey:@"lang"];
    }
    [dictionary setObject:order.preauth ? @"Y" : @"N" forKey:@"preauth"];
    [dictionary setObject:@"N" forKey:@"delayed"];
    [dictionary setObject:order.requiredRecToken ? @"Y" : @"N" forKey:@"required_rectoken"];
    [dictionary setObject:order.verification ? @"Y" : @"N" forKey:@"verification"];
    if (order.verificationType != 0) {
        [dictionary setObject:[PSOrder getVerificationName:order.verificationType] forKey:@"verification_type"];
    }
    [dictionary addEntriesFromDictionary:order.arguments];
    [dictionary setObject:URL_CALLBACK forKey:@"response_url"];
    [self call:@"/api/checkout/token" aParams:dictionary onSuccess:^(NSDictionary *response) {
        NSString *token = [response objectForKey:@"token"];
        success(token);
    } payDelegate:delegate];
}

- (void)checkout:(PSCard *)card
          aToken:(NSString *)token
          aEmail:(NSString *)email
       onSuccess:(void (^)(PSCheckout *checkout))success
     payDelegate:(id<PSPayCallbackDelegate>)delegate {
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                card.cardNumber, @"card_number",
                                card.cvv, @"cvv2",
                                [NSString stringWithFormat:@"%02d%02d", card.mm, card.yy], @"expiry_date",
                                @"card", @"payment_system",
                                token, @"token", nil];
    if (email != nil) {
        [dictionary setObject:email forKey:@"email"];
    }
    
    [self call:@"/api/checkout/ajax" aParams:dictionary onSuccess:^(NSDictionary *response) {
        NSString *url = [response objectForKey:@"url"];
        if ([URL_CALLBACK isEqualToString:url]) {
            PSCheckout *checkout = [[PSCheckout alloc] initCheckout:nil aUrl:url aAction:WITHOUT_3DS];
            success(checkout);
        } else {
            NSDictionary *sendData = [response objectForKey:@"send_data"];
            NSString *md = [NSString stringWithFormat:@"%@",[sendData objectForKey:@"MD"]];
            PSCheckout *checkout = [[PSCheckout alloc] initCheckout:[[PSSendData alloc] initSendData:md aPaReq:[sendData objectForKey:@"PaReq"] aTermUrl:[sendData objectForKey:@"TermUrl"]] aUrl:url aAction:WITH_3DS];
            success(checkout);
        }
    } payDelegate:delegate];
}

- (void)order:(NSString *)token
    onSuccess:(void (^)(PSReceipt *receipt))success
  payDelegate:(id<PSPayCallbackDelegate>)delegate {
    [self call:@"/api/checkout/merchant/order" aParams:@{@"token" : token} onSuccess:^(NSDictionary *response) {
        success([self parseOrder:[response objectForKey:@"order_data"]]);
    } payDelegate:delegate];
}

- (PSReceipt *)parseOrder:(NSDictionary *)orderData {
    NSDate *recTokenLifeTime;
    
    @try {
        recTokenLifeTime = [PSUtils dateFromString:[orderData objectForKey:@"rectoken_lifetime"] withFormat:DATE_AND_TIME_FORMAT];
    }
    @catch (NSException *exception) {
        recTokenLifeTime = nil;
    }
    
    NSDate *settlementDate;
    
    @try {
        settlementDate = [PSUtils dateFromString:[orderData objectForKey:@"settlement_date"] withFormat:DATE_FORMAT];
    }
    @catch (NSException *exception) {
        settlementDate = nil;
    }
    
    NSString *verificationStatus = [orderData objectForKey:@"verification_status"];
    PSReceiptVerificationStatus verificationStatusEnum;
    if (!verificationStatus) {
        verificationStatusEnum = PSReceiptVerificationStatusUnknown;
    } else {
        verificationStatusEnum = [PSReceipt getVerificationStatusSign:verificationStatus];
    }
    
    NSString *status = [orderData objectForKey:@"order_status"];
    PSReceiptStatus statusEnum;
    if (!status) {
        statusEnum = PSReceiptStatusUnknown;
    } else {
        statusEnum = [PSReceipt getStatusSign:status];
    }
    
    NSString *transitionType = [orderData objectForKey:@"tran_type"];
    PSReceiptTransationType transitionTypeEnum;
    if (!transitionType) {
        transitionTypeEnum = PSReceiptTransationTypeUnknown;
    } else {
        transitionTypeEnum = [PSReceipt getTransationTypeSign:transitionType];
    }
    
    NSString *cardType = [orderData objectForKey:@"card_type"];
    PSCardType cardTypeEnum;
    if (!cardType) {
        cardTypeEnum = PSCardTypeUnknown;
    } else {
        cardTypeEnum = [PSCard getCardType:[transitionType uppercaseString]];
    }
    
    NSInteger reversalAmount = [orderData objectForKey:@"reversal_amount"] ? [[orderData objectForKey:@"reversal_amount"] integerValue] : -1;
    
    NSInteger settlementAmount = [orderData objectForKey:@"settlement_amount"] ? [[orderData objectForKey:@"settlement_amount"] integerValue] : -1;
    
    NSInteger eci = [orderData objectForKey:@"eci"] ? [[orderData objectForKey:@"eci"] integerValue] : -1;
    
    NSInteger fee = [orderData objectForKey:@"fee"] ? [[orderData objectForKey:@"fee"] integerValue] : -1;
    
    NSInteger actualAmount = [orderData objectForKey:@"actual_amount"] ? [[orderData objectForKey:@"actual_amount"] integerValue] : -1;
    
    return [[PSReceipt alloc] initReceipt:orderData
                                aMaskCard:[orderData objectForKey:@"masked_card"]
                                 aCardBin:[[orderData objectForKey:@"card_bin"] integerValue]
                                  aAmount:[[orderData objectForKey:@"amount"] integerValue]
                               aPaymentId:[[orderData objectForKey:@"payment_id"] integerValue]
                                acurrency:[orderData objectForKey:@"currency"]
                                  aStatus:statusEnum
                          aTransationType:transitionTypeEnum
                         aSenderCellPhone:[orderData objectForKey:@"sender_cell_phone"]
                           aSenderAccount:[orderData objectForKey:@"sender_account"]
                                aCardType:cardTypeEnum aRrn:[orderData objectForKey:@"rrn"]
                            aApprovalCode:[orderData objectForKey:@"approval_code"]
                            aResponseCode:[orderData objectForKey:@"response_code"]
                               aProductId:[orderData objectForKey:@"product_id"]
                                aRecToken:[orderData objectForKey:@"rectoken"]
                        aRecTokenLifeTime:recTokenLifeTime
                          aReversalAmount:reversalAmount
                        aSettlementAmount:settlementAmount
                      aSettlementCurrency:[orderData objectForKey:@"settlement_currency"]
                          aSettlementDate:settlementDate
                                     aEci:eci
                                     aFee:fee
                            aActualAmount:actualAmount
                          aActualCurrency:[orderData objectForKey:@"actual_currency"]
                           aPaymentSystem:[orderData objectForKey:@"payment_system"]
                      aVerificationStatus:verificationStatusEnum
                               aSignature:[orderData objectForKey:@"signature"]];
}

- (void)url3ds:(PSCheckout *)checkout aPayCallbackDelegate:(id<PSPayCallbackDelegate>)delegate {
    void (^successCallback)(NSData * data) = ^(NSData *data) {
        NSString *htmlPageContent = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        PSPayConfirmation *confirmation = [[PSPayConfirmation alloc] initPayConfirmation:htmlPageContent
                                                                                    aUrl:checkout.url
                                                                             onConfirmed:^(NSString *jsonOfConfirmation)
                                           {
                                               NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[jsonOfConfirmation dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                                               NSString *url = [json objectForKey:@"url"];
                                               if (![url isEqualToString:URL_CALLBACK]) {
                                                   @throw [NSException exceptionWithName:@"" reason:nil userInfo:nil];
                                               }
                                               NSDictionary *orderData = [json objectForKey:@"params"];
                                               [self checkResponse:orderData];
                                               [delegate onPaidProcess:[self parseOrder:orderData]];
                                           }];
        [self.cloudipspView confirm:confirmation];
        [delegate onWaitConfirm];
    };
    if (checkout.sendData.paReq == nil) {
        NSDictionary *dictionary = @{@"MD" : checkout.sendData.md,
                                     @"TermUrl" : checkout.sendData.termUrl};
        
        
        [self callByUrl:[NSURL URLWithString:checkout.url]
                aParams:dictionary
              onSuccess:successCallback
            payDelegate:delegate];
    } else {
        NSDictionary *dictionary = @{@"MD" : checkout.sendData.md,
                                     @"PaReq" : checkout.sendData.paReq,
                                     @"TermUrl" : checkout.sendData.termUrl};
        
        [self callByUrl:[NSURL URLWithString:checkout.url]
                aParams:dictionary
              onSuccess:successCallback
            payDelegate:delegate
            onIntercept:^(NSMutableURLRequest *request) {
                NSString *post = [NSString stringWithFormat:@"MD=%@&PaReq=%@&TermUrl=%@", [PSCloudipspApi encodeToPercentEscapeString:checkout.sendData.md], [PSCloudipspApi encodeToPercentEscapeString:checkout.sendData.paReq], [PSCloudipspApi encodeToPercentEscapeString:checkout.sendData.termUrl]];
                NSData *postData = [post dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
                [request setHTTPMethod:@"POST"];
                [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
                [request setHTTPBody:postData];
            }];
    }
}

+ (NSString *)encodeToPercentEscapeString:(NSString *)string {
    CFStringRef strRef = CFURLCreateStringByAddingPercentEscapes(NULL,
                                                                 (CFStringRef) string,
                                                                 NULL,
                                                                 (CFStringRef) @"!*'();:@&=+$,/?%#[]",
                                                                 kCFStringEncodingUTF8);
    
    
    NSString* result = [NSString stringWithString: (__bridge NSString*)strRef];
    
    CFRelease(strRef);
    
    return result;
}


- (void)pay:(PSCard *)card aOrder:(PSOrder *)order aPayCallbackDelegate:(id<PSPayCallbackDelegate>)payCallbackDelegate {
    if (![card isValidCard]) {
        @throw [NSException exceptionWithName:@"PSIllegalArgumentException"
                                       reason:@"Card should be valid"
                                     userInfo:nil];
    }
    
    PSPayCallbackDelegateMainWrapper *wrapper = [PSPayCallbackDelegateMainWrapper wrapperWithOrigin:payCallbackDelegate];
    
    [self getToken:order onSuccess:^(NSString *token) {
        [self checkout:card aToken:token aEmail:order.email onSuccess:^(PSCheckout *checkout) {
            [self payContinue:checkout aToken:token aWrapper:wrapper];
        } payDelegate:wrapper];
    } payDelegate:wrapper];
}

- (void)payToken:(PSCard *)card aToken:(NSString *)token aPayCallbackDelegate:(id<PSPayCallbackDelegate>)payCallbackDelegate {
    if (![card isValidCard]) {
        @throw [NSException exceptionWithName:@"PSIllegalArgumentException"
                                       reason:@"Card should be valid"
                                     userInfo:nil];
    }
    
    PSPayCallbackDelegateMainWrapper *wrapper = [PSPayCallbackDelegateMainWrapper wrapperWithOrigin:payCallbackDelegate];
    
    [self checkout:card aToken:token aEmail:nil onSuccess:^(PSCheckout *checkout) {
        [self payContinue:checkout aToken:token aWrapper:wrapper];
    } payDelegate:wrapper];
}

- (void)payContinue:(PSCheckout *)checkout
                   aToken:(NSString *)token
                 aWrapper:(PSPayCallbackDelegateMainWrapper *)wrapper {
    if (checkout.action == WITHOUT_3DS) {
        [self order:token onSuccess:^(PSReceipt *receipt) {
            [wrapper onPaidProcess:receipt];
        } payDelegate:wrapper];
    } else {
        [self url3ds:checkout aPayCallbackDelegate:wrapper];
    }
}

- (UIViewController *)applePay:(NSString *)appleMerchantId
                        aOrder:(PSOrder *)order
          aPayCallbackDelegate:(id<PSPayCallbackDelegate>)payCallbackDelegate {
    PKPaymentRequest *paymentRequest = [[PKPaymentRequest alloc] init];
    paymentRequest.countryCode = @"US";
    paymentRequest.supportedNetworks = @[PKPaymentNetworkVisa, PKPaymentNetworkMasterCard, PKPaymentNetworkAmex];
    paymentRequest.merchantCapabilities = PKMerchantCapability3DS;
    paymentRequest.merchantIdentifier = appleMerchantId;
    paymentRequest.currencyCode = order.currency;

    NSDecimalNumber *amount = [[NSDecimalNumber alloc] initWithMantissa:order.amount exponent:-2 isNegative:NO];
    PKPaymentSummaryItem *item = [PKPaymentSummaryItem summaryItemWithLabel: order.about amount:amount];
    paymentRequest.paymentSummaryItems = @[item];

    self.applePayOrder = order;
    self.applePayPayCallbackDelegate = payCallbackDelegate;

    PKPaymentAuthorizationViewController *controller = [[PKPaymentAuthorizationViewController alloc] initWithPaymentRequest:paymentRequest];
    controller.delegate = self;
    return controller;
}
    
- (void)paymentAuthorizationViewControllerDidFinish:(PKPaymentAuthorizationViewController *)controller {
    [controller dismissViewControllerAnimated:YES completion:nil];
}
    
- (void)paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)controller
                       didAuthorizePayment:(PKPayment *)payment
                                   handler:(void (^)(PKPaymentAuthorizationResult *result))completion
    API_AVAILABLE(ios(11.0))
{
    PSPayCallbackDelegateApplePayWrapper *applePayWrapper = [PSPayCallbackDelegateApplePayWrapper wrapperWithOrigin:self.applePayPayCallbackDelegate andApplePayCallback:completion];
    
    [self processApplePay:payment payDelegate:applePayWrapper];
}

- (void)processApplePay:(PKPayment *)payment payDelegate:(id<PSPayCallbackDelegate>)delegate
    API_AVAILABLE(ios(11.0))
{
    NSError *jsonError;
        
    NSDictionary *paymentData = [NSJSONSerialization JSONObjectWithData:payment.token.paymentData options:NSJSONReadingMutableContainers error:&jsonError];
    NSDictionary *paymentMethod = @{
                                        @"displayName":payment.token.paymentMethod.displayName,
                                        @"network":payment.token.paymentMethod.network,
                                        @"type": [PSCloudipspApi paymentMethodName: payment.token.paymentMethod.type],
                                        };
    NSDictionary *paymentToken = @{
                                       @"paymentData": paymentData,
                                       @"paymentMethod": paymentMethod,
                                       @"transactionIdentifier": payment.token.transactionIdentifier
                                       };
    NSMutableDictionary *data = [NSMutableDictionary new];
    [data setObject:paymentToken forKey:@"token"];
    if (payment.shippingContact != nil) {
        NSDictionary *shipingContact = @{
                                             @"emailAddress": payment.shippingContact.emailAddress,
                                             @"familyName": payment.shippingContact.name.familyName,
                                             @"givenName": payment.shippingContact.name.givenName,
                                             @"phoneNumber": payment.shippingContact.phoneNumber.stringValue,
                                             };
        [data setObject:shipingContact forKey:@"shippingContact"];
    }
        
    PSPayCallbackDelegateMainWrapper *mainDelegate = [PSPayCallbackDelegateMainWrapper wrapperWithOrigin:delegate];
    
    [self getToken:self.applePayOrder onSuccess:^(NSString *token) {
        [self checkoutApplePay:data aToken:token aEmail:self.applePayOrder.email onSuccess:^(PSCheckout *checkout) {
            if (checkout.action == WITHOUT_3DS) {
                [self order:token onSuccess:^(PSReceipt *receipt) {
                    [mainDelegate onPaidProcess:receipt];
                } payDelegate:mainDelegate];
            } else {
                [self url3ds:checkout aPayCallbackDelegate:mainDelegate];
            }
        } payDelegate:mainDelegate];
    } payDelegate:mainDelegate];
}

- (void)checkoutApplePay:(NSDictionary *)paymentData
                  aToken:(NSString *)token
                  aEmail:(NSString *)email
               onSuccess:(void (^)(PSCheckout *checkout))success
             payDelegate:(id<PSPayCallbackDelegate>)delegate {
    NSDictionary *dictionary = [NSDictionary dictionaryWithObjectsAndKeys:
                                paymentData, @"data",
                                @"mobile_pay", @"payment_system",
                                token, @"token",
                                email, @"email", nil];
    
    [self call:@"/api/checkout/ajax" aParams:dictionary onSuccess:^(NSDictionary *response) {
        NSString *url = [response objectForKey:@"url"];
        if ([URL_CALLBACK isEqualToString:url]) {
            PSCheckout *checkout = [[PSCheckout alloc] initCheckout:nil aUrl:url aAction:WITHOUT_3DS];
            success(checkout);
        } else {
            NSDictionary *sendData = [response objectForKey:@"send_data"];
            NSString *md = [NSString stringWithFormat:@"%@",[sendData objectForKey:@"MD"]];
            PSCheckout *checkout = [[PSCheckout alloc] initCheckout:[[PSSendData alloc] initSendData:md aPaReq:[sendData objectForKey:@"PaReq"] aTermUrl:[sendData objectForKey:@"TermUrl"]] aUrl:url aAction:WITH_3DS];
            success(checkout);
        }
    } payDelegate:delegate];
}
    
#pragma mark - Localization

+ (void)setLocalization:(PSLocalization *)localization {
    _localization = localization;
}

+ (PSLocalization *)getLocalization {
    if (_localization == nil) {
        NSString *language = [[NSLocale currentLocale] objectForKey:NSLocaleLanguageCode];
        if ([language isEqualToString:@"uk"]) {
            return [PSLocalization uk];
        } else if ([language isEqualToString:@"ru"]) {
            return [PSLocalization ru];
        } else {
            return [PSLocalization en];
        }
    } else {
        return _localization;
    }
}

+ (NSString *)paymentMethodName:(PKPaymentMethodType)type API_AVAILABLE(ios(9.0)){
    switch (type) {
        case PKPaymentMethodTypeDebit:
            return @"debit";
        case PKPaymentMethodTypeCredit:
            return @"credit";
        case PKPaymentMethodTypePrepaid:
            return @"prepaid";
        case PKPaymentMethodTypeStore:
            return @"store";
        default:
            return @"unknown";
    }
}

@end
