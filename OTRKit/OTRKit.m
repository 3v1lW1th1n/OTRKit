/*
 * OTRKit.m
 * OTRKit
 *
 * Created by Chris Ballinger on 9/4/11.
 * Copyright (c) 2012 Chris Ballinger. All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 
 * Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 * 
 * Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 * 
 * Neither the name of the project's author nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 * TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 */

#import "OTRKit.h"
#import "OTRTLV.h"
#import "proto.h"
#import "message.h"
#import "privkey.h"
#import "proto.h"

static NSString * const kOTRKitPrivateKeyFileName = @"otr.private_key";
static NSString * const kOTRKitFingerprintsFileName = @"otr.fingerprints";
static NSString * const kOTRKitInstanceTagsFileName =  @"otr.instance_tags";
static NSString * const kOTRKitErrorDomain       = @"org.chatsecure.OTRKit";

NSString const *kOTRKitUsernameKey    = @"kOTRKitUsernameKey";
NSString const *kOTRKitAccountNameKey = @"kOTRKitAccountNameKey";
NSString const *kOTRKitFingerprintKey = @"kOTRKitFingerprintKey";
NSString const *kOTRKitProtocolKey    = @"kOTRKitProtocolKey";
NSString const *kOTRKitTrustKey       = @"kOTRKitTrustKey";


@interface OTRKit()
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic) OtrlUserState userState;
@property (nonatomic, strong) NSDictionary *protocolMaxSize;
@end

@implementation OTRKit

+ (void) initialize {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        OTRL_INIT;
    });
}

- (void) dealloc {
    [self.pollTimer invalidate];
    otrl_userstate_free(self.userState);
    self.userState = NULL;
}

static OtrlPolicy policy_cb(void *opdata, ConnContext *context)
{
    OTRKit *otrKit = [OTRKit sharedInstance];
    return [otrKit otrlPolicy];
}

static void create_privkey_cb(void *opdata, const char *accountname,
                              const char *protocol)
{
    OTRKit *otrKit = [OTRKit sharedInstance];
    NSString *accountNameString = [NSString stringWithUTF8String:accountname];
    NSString *protocolString = [NSString stringWithUTF8String:protocol];
    if (otrKit.delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [otrKit.delegate otrKit:otrKit willStartGeneratingPrivateKeyForAccountName:accountNameString   protocol:protocolString];
        });
    }
    FILE *privf;
    NSString *path = [otrKit privateKeyPath];
    privf = fopen([path UTF8String], "w+b");
    // Generate Key
    otrl_privkey_generate_FILEp(otrKit.userState, privf, accountname, protocol);
    fclose(privf);
    if (otrKit.delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [otrKit.delegate otrKit:otrKit didFinishGeneratingPrivateKeyForAccountName:accountNameString protocol:protocolString error:nil];
        });
    }
}

- (void)checkIfGeneratingKeyForAccountName:(NSString *)accountName protocol:(NSString *)protocol completion:(void (^)(BOOL isGeneratingKey))completion
{
    if (!accountName.length || !protocol.length) {
        if (completion) {
            completion(NO);
        }
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        __block void *newkeyp;
        __block gcry_error_t generateError;
        generateError = otrl_privkey_generate_start(_userState,[accountName UTF8String],[protocol UTF8String],&newkeyp);
        if (!generateError) {
            otrl_privkey_generate_cancelled(_userState, newkeyp);
        }
        
        if (completion) {
            completion (generateError == gcry_error(GPG_ERR_EEXIST));
        }
    });
}

- (void) generatePrivateKeyIfNeededForAccountName:(NSString *)accountName protocol:(NSString *)protocol completionBlock:(void (^)(BOOL success, NSError *error))completionBlock {
    [self hasPrivateKeyForAccountName:accountName protocol:protocol completionBlock:^(BOOL hasPrivateKey) {
        if (hasPrivateKey) {
            completionBlock(YES, nil);
        } else {
            [self checkIfGeneratingKeyForAccountName:accountName protocol:protocol completion:^(BOOL isGeneratingKey) {
                if (isGeneratingKey) {
                    completionBlock(NO, [NSError errorWithDomain:kOTRKitErrorDomain code:100 userInfo:@{NSLocalizedDescriptionKey: @"Currently generating private key, please try again later."}]);
                } else {
                    [self generatePrivateKeyForAccountName:accountName protocol:protocol completionBlock:completionBlock];
                }
            }];
        }
    }];
}

- (void)hasPrivateKeyForAccountName:(NSString *)accountName protocol:(NSString *)protocol completionBlock:(void (^)(BOOL hasPrivateKey))completionBlock {
    if (!accountName.length || !protocol.length) {
        if (completionBlock) {
            completionBlock(NO);
        }
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completionBlock) {
            __block OtrlPrivKey *privateKey;
            privateKey = otrl_privkey_find(_userState, [accountName UTF8String], [protocol UTF8String]);
            __block BOOL result = NO;
            
            if (privateKey) {
                result = YES;
            }
            completionBlock(result);
        }
    });
}

-(void)generatePrivateKeyForAccountName:(NSString *)accountName protocol:(NSString *)protocol completionBlock:(void (^)(BOOL success, NSError *error))completionBlock {
    if (!accountName.length || !protocol.length) {
        if (completionBlock) {
            completionBlock(NO, [NSError errorWithDomain:kOTRKitErrorDomain code:101 userInfo:@{NSLocalizedDescriptionKey: @"accountName and protocol must have non-zero length."}]);
        }
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        void *newkeyp;
        gcry_error_t generateError;
        if (self.delegate) {
            [self.delegate otrKit:self willStartGeneratingPrivateKeyForAccountName:accountName protocol:protocol];
        }
        
        generateError = otrl_privkey_generate_start(_userState,[accountName UTF8String],[protocol UTF8String],&newkeyp);
        FILE *privf;
        NSString *path = [self privateKeyPath];
        privf = fopen([path UTF8String], "w+b");
        if (generateError == gcry_error(GPG_ERR_NO_ERROR)) {
            dispatch_async(self.isolationQueue, ^{
                otrl_privkey_generate_calculate(newkeyp);
                dispatch_async(dispatch_get_main_queue(), ^{
                    otrl_privkey_generate_finish_FILEp(_userState,newkeyp,privf);
                    fclose(privf);
                    if (completionBlock) {
                        completionBlock(YES, nil);
                    }
                    if (self.delegate) {
                        [self.delegate otrKit:self didFinishGeneratingPrivateKeyForAccountName:accountName protocol:protocol error:nil];
                    }
                });
            });
        } else {
            NSError *error = [self errorForGPGError:generateError];
            if (completionBlock) {
                completionBlock(NO, error);
            }
            if (self.delegate) {
                [self.delegate otrKit:self didFinishGeneratingPrivateKeyForAccountName:accountName protocol:protocol error:error];
            }
        }
    });
}

- (NSError*) errorForGPGError:(gcry_error_t)gpg_error {
    const char *gpg_error_string = gcry_strerror(gpg_error);
    const char *gpg_error_source = gcry_strsource(gpg_error);
    gpg_err_code_t gpg_error_code = gcry_err_code(gpg_error);
    int errorCode = gcry_err_code_to_errno(gpg_error_code);
    NSString *errorString = nil;
    NSString *errorSource = nil;
    if (gpg_error_string) {
        errorString = [NSString stringWithUTF8String:gpg_error_string];
    }
    if (gpg_error_source) {
        errorSource = [NSString stringWithUTF8String:gpg_error_source];
    }
    NSMutableString *errorDescription = [NSMutableString string];
    if (errorString) {
        [errorDescription appendString:errorString];
    }
    if (errorSource) {
        [errorDescription appendString:errorSource];
    }
    NSError *error = [NSError errorWithDomain:kOTRKitErrorDomain code:errorCode userInfo:@{NSLocalizedDescriptionKey: errorDescription}];
    return error;
}

static int is_logged_in_cb(void *opdata, const char *accountname,
                           const char *protocol, const char *recipient)
{
    OTRKit *otrKit = [OTRKit sharedInstance];
    if (!otrKit.delegate) {
        return -1;
    }
    return [otrKit.delegate otrKit:otrKit
               isRecipientLoggedIn:[NSString stringWithUTF8String:recipient]
                       accountName:[NSString stringWithUTF8String:accountname]
                          protocol:[NSString stringWithUTF8String:protocol]];
}

static void inject_message_cb(void *opdata, const char *accountname,
                              const char *protocol, const char *recipient, const char *message)
{
    OTRKit *otrKit = [OTRKit sharedInstance];
    if (!otrKit.delegate) {
        return;
    }
    [otrKit.delegate otrKit:otrKit injectMessage:[NSString stringWithUTF8String:message] recipient:[NSString stringWithUTF8String:recipient] accountName:[NSString stringWithUTF8String:accountname] protocol:[NSString stringWithUTF8String:protocol]];
}

static void update_context_list_cb(void *opdata)
{
}

static void confirm_fingerprint_cb(void *opdata, OtrlUserState us,
                                   const char *accountname, const char *protocol, const char *username,
                                   unsigned char fingerprint[20])
{
    OTRKit *otrKit = [OTRKit sharedInstance];

    char our_hash[OTRL_PRIVKEY_FPRINT_HUMAN_LEN], their_hash[OTRL_PRIVKEY_FPRINT_HUMAN_LEN];
    
    ConnContext *context = otrl_context_find(otrKit.userState, username,accountname, protocol,OTRL_INSTAG_BEST, NO,NULL,NULL, NULL);
    if (!context) {
        return;
    }
    
    otrl_privkey_fingerprint(otrKit.userState, our_hash, context->accountname, context->protocol);
    
    otrl_privkey_hash_to_human(their_hash, fingerprint);
    
    if (otrKit.delegate && [otrKit.delegate respondsToSelector:@selector(otrKit:showFingerprintConfirmationForAccountName:protocol:userName:theirHash:ourHash:)]) {
        [otrKit.delegate otrKit:otrKit showFingerprintConfirmationForAccountName:[NSString stringWithUTF8String:accountname] protocol:[NSString stringWithUTF8String:protocol] userName:[NSString stringWithUTF8String:username] theirHash:[NSString stringWithUTF8String:their_hash] ourHash:[NSString stringWithUTF8String:our_hash]];
    }
}

static void write_fingerprints_cb(void *opdata)
{
    OTRKit *otrKit = [OTRKit sharedInstance];
    FILE *storef;
    NSString *path = [otrKit fingerprintsPath];
    storef = fopen([path UTF8String], "wb");
    if (!storef) return;
    otrl_privkey_write_fingerprints_FILEp(otrKit.userState, storef);
    fclose(storef);
}


static void gone_secure_cb(void *opdata, ConnContext *context)
{
    OTRKit *otrKit = [OTRKit sharedInstance];
    [otrKit updateEncryptionStatusWithContext:context];
}

static void gone_insecure_cb(void *opdata, ConnContext *context) // this method is never called
{
    OTRKit *otrKit = [OTRKit sharedInstance];
    [otrKit updateEncryptionStatusWithContext:context];
}

- (void) updateEncryptionStatusWithContext:(ConnContext*)context {
    if (self.delegate && [self.delegate respondsToSelector:@selector(otrKit:updateMessageState:username:accountName:protocol:)]) {
        OTRKitMessageState messageState = [self messageStateForUsername:[NSString stringWithUTF8String:context->username] accountName:[NSString stringWithUTF8String:context->accountname] protocol:[NSString stringWithUTF8String:context->protocol]];
        [self.delegate otrKit:self updateMessageState:messageState username:[NSString stringWithUTF8String:context->username] accountName:[NSString stringWithUTF8String:context->accountname] protocol:[NSString stringWithUTF8String:context->protocol]];
    } else {
        NSLog(@"Your delegate must implement the updateMessageStateForUsername:accountName:protocol:messageState: selector!");
    }
}

static void still_secure_cb(void *opdata, ConnContext *context, int is_reply)
{
    OTRKit *otrKit = [OTRKit sharedInstance];
    [otrKit updateEncryptionStatusWithContext:context];
}


static int max_message_size_cb(void *opdata, ConnContext *context)
{
    NSString *protocol = [NSString stringWithUTF8String:context->protocol];
    if (!protocol.length) {
        return 0;
    }
    
    OTRKit *otrKit = [OTRKit sharedInstance];
    if (otrKit.delegate && [otrKit.delegate respondsToSelector:@selector(otrKit:maxMessageSizeForProtocol:)]) {
        return [otrKit.delegate otrKit:otrKit maxMessageSizeForProtocol:[NSString stringWithUTF8String:context->protocol]];
    }
    
    NSNumber *maxMessageSize = [otrKit.protocolMaxSize objectForKey:protocol];
    return maxMessageSize.intValue;
}

static const char* otr_error_message_cb(void *opdata, ConnContext *context,
                                        OtrlErrorCode err_code)
{
    NSString *errorString = nil;
    switch (err_code)
    {
        case OTRL_ERRCODE_NONE :
            break;
        case OTRL_ERRCODE_ENCRYPTION_ERROR :
            errorString = @"Error occurred encrypting message.";
            break;
        case OTRL_ERRCODE_MSG_NOT_IN_PRIVATE :
            if (context) {
                errorString = [NSString stringWithFormat:@"You sent encrypted data to %s, who wasn't expecting it.", context->accountname];
            }
            break;
        case OTRL_ERRCODE_MSG_UNREADABLE :
            errorString = @"You transmitted an unreadable encrypted message.";
            break;
        case OTRL_ERRCODE_MSG_MALFORMED :
            errorString = @"You transmitted a malformed data message.";
            break;
    }
    return [errorString UTF8String];
}

static void otr_error_message_free_cb(void *opdata, const char *err_msg)
{
    // Leak memory here instead of crashing:
    // if (err_msg) free((char*)err_msg);
}

static const char *resent_msg_prefix_cb(void *opdata, ConnContext *context)
{
    NSString *resentString = @"[resent]";
	return [resentString UTF8String];
}

static void resent_msg_prefix_free_cb(void *opdata, const char *prefix)
{
    // Leak memory here instead of crashing:
	// if (prefix) free((char*)prefix);
}

static void handle_smp_event_cb(void *opdata, OtrlSMPEvent smp_event,
                                ConnContext *context, unsigned short progress_percent,
                                char *question)
{
    /*
    if (!context) return;
    switch (smp_event)
    {
        case OTRL_SMPEVENT_NONE :
            break;
        case OTRL_SMPEVENT_ASK_FOR_SECRET :
            otrg_dialog_socialist_millionaires(context);
            break;
        case OTRL_SMPEVENT_ASK_FOR_ANSWER :
            otrg_dialog_socialist_millionaires_q(context, question);
            break;
        case OTRL_SMPEVENT_CHEATED :
            otrg_plugin_abort_smp(context);
            // FALLTHROUGH 
        case OTRL_SMPEVENT_IN_PROGRESS :
        case OTRL_SMPEVENT_SUCCESS :
        case OTRL_SMPEVENT_FAILURE :
        case OTRL_SMPEVENT_ABORT :
            otrg_dialog_update_smp(context,
                                   smp_event, ((gdouble)progress_percent)/100.0);
            break;
        case OTRL_SMPEVENT_ERROR :
            otrg_plugin_abort_smp(context);
            break;
    }
     */
}

static void handle_msg_event_cb(void *opdata, OtrlMessageEvent msg_event,
                                ConnContext *context, const char* message, gcry_error_t err)
{
    /*
    PurpleConversation *conv = NULL;
    gchar *buf;
    OtrlMessageEvent * last_msg_event;
    
    if (!context) return;
    
    conv = otrg_plugin_context_to_conv(context, 1);
    last_msg_event = g_hash_table_lookup(conv->data, "otr-last_msg_event");
    
    switch (msg_event)
    {
        case OTRL_MSGEVENT_NONE:
            break;
        case OTRL_MSGEVENT_ENCRYPTION_REQUIRED:
            buf = g_strdup_printf(_("You attempted to send an "
                                    "unencrypted message to %s"), context->username);
            display_otr_message_or_notify(opdata, context->accountname,
                                          context->protocol, context->username, _("Attempting to"
                                                                                  " start a private conversation..."), 1, OTRL_NOTIFY_WARNING,
                                          _("OTR Policy Violation"), buf,
                                          _("Unencrypted messages to this recipient are "
                                            "not allowed.  Attempting to start a private "
                                            "conversation.\n\nYour message will be "
                                            "retransmitted when the private conversation "
                                            "starts."));
            g_free(buf);
            break;
        case OTRL_MSGEVENT_ENCRYPTION_ERROR:
            display_otr_message_or_notify(opdata, context->accountname,
                                          context->protocol, context->username, _("An error occurred "
                                                                                  "when encrypting your message.  The message was not sent."),
                                          1, OTRL_NOTIFY_ERROR, _("Error encrypting message"),
                                          _("An error occurred when encrypting your message"),
                                          _("The message was not sent."));
            break;
        case OTRL_MSGEVENT_CONNECTION_ENDED:
            buf = g_strdup_printf(_("%s has already closed his/her private "
                                    "connection to you"), context->username);
            display_otr_message_or_notify(opdata, context->accountname,
                                          context->protocol, context->username, _("Your message "
                                                                                  "was not sent.  Either end your private conversation, "
                                                                                  "or restart it."), 1, OTRL_NOTIFY_ERROR,
                                          _("Private connection closed"), buf,
                                          _("Your message was not sent.  Either close your "
                                            "private connection to him, or refresh it."));
            g_free(buf);
            break;
        case OTRL_MSGEVENT_SETUP_ERROR:
            if (!err) {
                err = GPG_ERR_INV_VALUE;
            }
            switch(gcry_err_code(err)) {
                case GPG_ERR_INV_VALUE:
                    buf = g_strdup(_("Error setting up private "
                                     "conversation: Malformed message received"));
                    break;
                default:
                    buf = g_strdup_printf(_("Error setting up private "
                                            "conversation: %s"), gcry_strerror(err));
                    break;
            }
            
            display_otr_message_or_notify(opdata, context->accountname,
                                          context->protocol, context->username, buf, 1,
                                          OTRL_NOTIFY_ERROR, _("OTR Error"), buf, NULL);
            g_free(buf);
            break;
        case OTRL_MSGEVENT_MSG_REFLECTED:
            display_otr_message_or_notify(opdata,
                                          context->accountname, context->protocol,
                                          context->username,
                                          _("We are receiving our own OTR messages.  "
                                            "You are either trying to talk to yourself, "
                                            "or someone is reflecting your messages back "
                                            "at you."), 1, OTRL_NOTIFY_ERROR,
                                          _("OTR Error"), _("We are receiving our own OTR messages."),
                                          _("You are either trying to talk to yourself, "
                                            "or someone is reflecting your messages back "
                                            "at you."));
            break;
        case OTRL_MSGEVENT_MSG_RESENT:
            buf = g_strdup_printf(_("<b>The last message to %s was resent."
                                    "</b>"), context->username);
            display_otr_message_or_notify(opdata, context->accountname,
                                          context->protocol, context->username, buf, 1,
                                          OTRL_NOTIFY_INFO, _("Message resent"), buf, NULL);
            g_free(buf);
            break;
        case OTRL_MSGEVENT_RCVDMSG_NOT_IN_PRIVATE:
            buf = g_strdup_printf(_("<b>The encrypted message received from "
                                    "%s is unreadable, as you are not currently communicating "
                                    "privately.</b>"), context->username);
            display_otr_message_or_notify(opdata, context->accountname,
                                          context->protocol, context->username, buf, 1,
                                          OTRL_NOTIFY_INFO, _("Unreadable message"), buf, NULL);
            g_free(buf);
            break;
        case OTRL_MSGEVENT_RCVDMSG_UNREADABLE:
            buf = g_strdup_printf(_("We received an unreadable "
                                    "encrypted message from %s."), context->username);
            display_otr_message_or_notify(opdata, context->accountname,
                                          context->protocol, context->username, buf, 1,
                                          OTRL_NOTIFY_ERROR, _("OTR Error"), buf, NULL);
            g_free(buf);
            break;
        case OTRL_MSGEVENT_RCVDMSG_MALFORMED:
            buf = g_strdup_printf(_("We received a malformed data "
                                    "message from %s."), context->username);
            display_otr_message_or_notify(opdata, context->accountname,
                                          context->protocol, context->username, buf, 1,
                                          OTRL_NOTIFY_ERROR, _("OTR Error"), buf, NULL);
            g_free(buf);
            break;
        case OTRL_MSGEVENT_LOG_HEARTBEAT_RCVD:
            buf = g_strdup_printf(_("Heartbeat received from %s.\n"),
                                  context->username);
            log_message(opdata, buf);
            g_free(buf);
            break;
        case OTRL_MSGEVENT_LOG_HEARTBEAT_SENT:
            buf = g_strdup_printf(_("Heartbeat sent to %s.\n"),
                                  context->username);
            log_message(opdata, buf);
            g_free(buf);
            break;
        case OTRL_MSGEVENT_RCVDMSG_GENERAL_ERR:
            display_otr_message_or_notify(opdata, context->accountname,
                                          context->protocol, context->username, message, 1,
                                          OTRL_NOTIFY_ERROR, _("OTR Error"), message, NULL);
            break;
        case OTRL_MSGEVENT_RCVDMSG_UNENCRYPTED:
            buf = g_strdup_printf(_("<b>The following message received "
                                    "from %s was <i>not</i> encrypted: [</b>%s<b>]</b>"),
                                  context->username, message);
            display_otr_message_or_notify(opdata, context->accountname,
                                          context->protocol, context->username, buf, 1,
                                          OTRL_NOTIFY_INFO, _("Received unencrypted message"),
                                          buf, NULL);
            emit_msg_received(context, buf);
            g_free(buf);
            break;
        case OTRL_MSGEVENT_RCVDMSG_UNRECOGNIZED:
            buf = g_strdup_printf(_("Unrecognized OTR message received "
                                    "from %s.\n"), context->username);
            log_message(opdata, buf);
            g_free(buf);
            break;
        case OTRL_MSGEVENT_RCVDMSG_FOR_OTHER_INSTANCE:
            if (*last_msg_event == msg_event) {
                break;
            }
            buf = g_strdup_printf(_("%s has sent a message intended for a "
                                    "different session. If you are logged in multiple times, "
                                    "another session may have received the message."),
                                  context->username);
            display_otr_message_or_notify(opdata, context->accountname,
                                          context->protocol, context->username, buf, 1,
                                          OTRL_NOTIFY_INFO, _("Received message for a different "
                                                              "session"), buf, NULL);
            g_free(buf);
            break;
    }
    
    *last_msg_event = msg_event;
     */
}

static void create_instag_cb(void *opdata, const char *accountname,
                             const char *protocol)
{
    OTRKit *otrKit = [OTRKit sharedInstance];
    FILE *instagf;
    NSString *path = [otrKit instanceTagsPath];
    instagf = fopen([path UTF8String], "w+b");
    otrl_instag_generate_FILEp(otrKit.userState, instagf, accountname, protocol);
    fclose(instagf);
}

/* Called by libotr */
static void timer_control_cb(void *opdata, unsigned int interval)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        OTRKit *otrKit = [OTRKit sharedInstance];
        if (otrKit.pollTimer) {
            [otrKit.pollTimer invalidate];
            otrKit.pollTimer = nil;
        }
        if (interval > 0) {
            otrKit.pollTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:otrKit selector:@selector(messagePoll:) userInfo:nil repeats:YES];
        }
    });
}

static OtrlMessageAppOps ui_ops = {
    policy_cb,
    create_privkey_cb,
    is_logged_in_cb,
    inject_message_cb,
    update_context_list_cb,
    confirm_fingerprint_cb,
    write_fingerprints_cb,
    gone_secure_cb,
    gone_insecure_cb,
    still_secure_cb,
    max_message_size_cb,
    NULL,                   /* account_name */
    NULL,                   /* account_name_free */
#ifdef DUMP_RECEIVED_SYMKEY
    received_symkey_cb,
#else
    NULL,		    /* received_symkey */
#endif
    otr_error_message_cb,
    otr_error_message_free_cb,
    resent_msg_prefix_cb,
    resent_msg_prefix_free_cb,
    handle_smp_event_cb,
    handle_msg_event_cb,
    create_instag_cb,
    NULL,		    /* convert_data */
    NULL,		    /* convert_data_free */
    timer_control_cb
};

+ (instancetype) sharedInstance {
    static OTRKit *_sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedInstance = [[OTRKit alloc] init];
    });
    return _sharedInstance;
}

- (void) setupWithDataPath:(NSString *)dataPath {
    if (!dataPath) {
        self.dataPath = [self documentsDirectory];
    } else {
        self.dataPath = dataPath;
    }
   self.protocolMaxSize = @{@"prpl-msn":   @(1409),
                            @"prpl-icq":   @(2346),
                            @"prpl-aim":   @(2343),
                            @"prpl-yahoo": @(832),
                            @"prpl-gg":    @(1999),
                            @"prpl-irc":   @(417),
                            @"prpl-oscar": @(2343)};
    self.isolationQueue = dispatch_queue_create("OTRKit Processing Queue", DISPATCH_QUEUE_SERIAL);
    // initialize OTR
    self.userState = otrl_userstate_create();
    
    FILE *privf;
    NSString *path = [self privateKeyPath];
    privf = fopen([path UTF8String], "rb");
    
    if(privf)
        otrl_privkey_read_FILEp(_userState, privf);
    fclose(privf);
    
    FILE *storef;
    path = [self fingerprintsPath];
    storef = fopen([path UTF8String], "rb");
    
    if (storef)
        otrl_privkey_read_fingerprints_FILEp(_userState, storef, NULL, NULL);
    fclose(storef);
    
    FILE *tagf;
    path = [self instanceTagsPath];
    tagf = fopen([path UTF8String], "rb");
    if (tagf)
        otrl_instag_read_FILEp(_userState, tagf);
    fclose(tagf);
}

- (NSString*) documentsDirectory {
  NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
  NSString *documentsDirectory = [paths objectAtIndex:0];
  return documentsDirectory;
}

- (NSString*) privateKeyPath {
  return [self.dataPath stringByAppendingPathComponent:kOTRKitPrivateKeyFileName];
}

- (NSString*) fingerprintsPath {
  return [self.dataPath stringByAppendingPathComponent:kOTRKitFingerprintsFileName];
}

- (NSString*) instanceTagsPath {
    return [self.dataPath stringByAppendingPathComponent:kOTRKitInstanceTagsFileName];
}

- (void) messagePoll:(NSTimer*)timer {
    if (self.userState) {
        otrl_message_poll(_userState, &ui_ops, (__bridge void *)(self));
    } else {
        [timer invalidate];
    }
}

- (void)decodeMessage:(NSString *)message sender:(NSString*)sender accountName:(NSString*)accountName protocol:(NSString*)protocol {
    dispatch_async(self.isolationQueue, ^{
        if (![message length] || ![sender length] || ![accountName length] || ![protocol length]) {
            return;
        }
        int ignore_message;
        char *newmessage = NULL;
        ConnContext *context = [self contextForUsername:sender accountName:accountName protocol:protocol];
        
        OtrlTLV *otr_tlvs = NULL;
        ignore_message = otrl_message_receiving(_userState, &ui_ops, (__bridge void *)(self),[accountName UTF8String], [protocol UTF8String], [sender UTF8String], [message UTF8String], &newmessage, &otr_tlvs, &context, NULL, NULL);
        NSString *decodedMessage = nil;
        
        NSArray *tlvs = nil;
        if (otr_tlvs) {
            tlvs = [self tlvArrayForTLVChain:otr_tlvs];
        }
        
        if (context) {
            if (context->msgstate == OTRL_MSGSTATE_FINISHED) {
                [self disableEncryptionWithRecipient:sender accountName:accountName protocol:protocol];
            }
        }
        
        
        if(ignore_message == 0)
        {
            if(newmessage) {
                decodedMessage = [NSString stringWithUTF8String:newmessage];
            } else {
                decodedMessage = message;
            }
            if (self.delegate) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate otrKit:self decodedMessage:decodedMessage tlvs:tlvs sender:sender accountName:accountName protocol:protocol];
                });
            }
        }
        
        if (newmessage) {
            otrl_message_free(newmessage);
        }
        if (otr_tlvs) {
            otrl_tlv_free(otr_tlvs);
        }
    });
}

- (OtrlTLV*)tlvChainForTLVs:(NSArray*)tlvs {
    if (!tlvs || !tlvs.count) {
        return NULL;
    }
    OtrlTLV *root_tlv = NULL;
    OtrlTLV *current_tlv = NULL;
    NSUInteger validTLVCount = 0;
    for (OTRTLV *tlv in tlvs) {
        if (!tlv.isValidLength) {
            continue;
        }
        OtrlTLV *new_tlv = otrl_tlv_new(tlv.type, tlv.data.length, tlv.data.bytes);
        if (validTLVCount == 0) {
            root_tlv = new_tlv;
        } else {
            current_tlv->next = new_tlv;
        }
        current_tlv = new_tlv;
        validTLVCount++;
    }
    return root_tlv;
}

- (NSArray*)tlvArrayForTLVChain:(OtrlTLV*)tlv_chain {
    if (!tlv_chain) {
        return nil;
    }
    NSMutableArray *tlvArray = [NSMutableArray array];
    OtrlTLV *current_tlv = tlv_chain;
    while (current_tlv) {
        NSData *tlvData = [NSData dataWithBytes:current_tlv->data length:current_tlv->len];
        OTRTLVType type = current_tlv->type;
        OTRTLV *tlv = [[OTRTLV alloc] initWithType:type data:tlvData];
        [tlvArray addObject:tlv];
        current_tlv = current_tlv->next;
    }
    return tlvArray;
}

- (void)encodeMessage:(NSString *)message tlvs:(NSArray*)tlvs recipient:(NSString *)recipient accountName:(NSString *)accountName protocol:(NSString *)protocol completionBlock:(void (^)(BOOL success, NSError *error))completionBlock {
    [self generatePrivateKeyIfNeededForAccountName:accountName protocol:protocol completionBlock:^(BOOL success, NSError *error) {
        if (!success) {
            completionBlock(NO, error);
        }
        dispatch_async(self.isolationQueue, ^{
            gcry_error_t err;
            char *newmessage = NULL;
            
            ConnContext *context = [self contextForUsername:recipient accountName:accountName protocol:protocol];
            
            OtrlTLV *otr_tlvs = [self tlvChainForTLVs:tlvs];
            
            err = otrl_message_sending(_userState, &ui_ops, (__bridge void *)(self),
                                       [accountName UTF8String], [protocol UTF8String], [recipient UTF8String], OTRL_INSTAG_BEST, [message UTF8String], otr_tlvs, &newmessage, OTRL_FRAGMENT_SEND_ALL, &context,
                                       NULL, NULL);
            
            if (otr_tlvs) {
                otrl_tlv_free(otr_tlvs);
            }
            
            if (err != gcry_err_code(GPG_ERR_NO_ERROR)) {
                NSError *error = [self errorForGPGError:err];
                completionBlock(NO, error);
                return;
            }
            
            NSString *encodedMessage = nil;
            if (newmessage) {
                encodedMessage = [NSString stringWithUTF8String:newmessage];
                otrl_message_free(newmessage);
            }
            
            if (encodedMessage) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionBlock(YES, nil);
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionBlock(NO, [NSError errorWithDomain:kOTRKitErrorDomain code:102 userInfo:@{NSLocalizedDescriptionKey: @"Message failed to be encoded."}]);
                });
            }
        });
        
    }];
}

- (void)inititateEncryptionWithRecipient:(NSString*)recipient
                             accountName:(NSString*)accountName
                                protocol:(NSString*)protocol
{
    [self encodeMessage:@"?OTR?" tlvs:nil recipient:recipient accountName:accountName protocol:protocol completionBlock:nil];
}

- (void)disableEncryptionWithRecipient:(NSString*)recipient
                           accountName:(NSString*)accountName
                              protocol:(NSString*)protocol {
  otrl_message_disconnect_all_instances(_userState, &ui_ops, (__bridge void *)(self), [accountName UTF8String], [protocol UTF8String], [recipient UTF8String]);
  [self updateEncryptionStatusWithContext:[self contextForUsername:recipient accountName:accountName protocol:protocol]];
}

- (NSString*) fingerprintForAccountName:(NSString*)accountName protocol:(NSString*) protocol {
    NSString *fingerprintString = nil;
    char our_hash[OTRL_PRIVKEY_FPRINT_HUMAN_LEN];
    otrl_privkey_fingerprint(_userState, our_hash, [accountName UTF8String], [protocol UTF8String]);
    fingerprintString = [NSString stringWithUTF8String:our_hash];
    return fingerprintString;
}

- (ConnContext*) contextForUsername:(NSString*)username accountName:(NSString*)accountName protocol:(NSString*) protocol {
    ConnContext *context = otrl_context_find(_userState, [username UTF8String], [accountName UTF8String], [protocol UTF8String], OTRL_INSTAG_BEST, NO,NULL,NULL, NULL);
    return context;
}

- (Fingerprint *)internalActiveFingerprintForUsername:(NSString*)username accountName:(NSString*)accountName protocol:(NSString*) protocol {
    Fingerprint * fingerprint = nil;
    ConnContext *context = [self contextForUsername:username accountName:accountName protocol:protocol];
    if(context)
    {
        fingerprint = context->active_fingerprint;
    }
    return fingerprint;
    
}

- (NSString *)activeFingerprintForUsername:(NSString*)username accountName:(NSString*)accountName protocol:(NSString*) protocol {
    
    NSString *fingerprintString = nil;
    char their_hash[OTRL_PRIVKEY_FPRINT_HUMAN_LEN];
    Fingerprint * fingerprint = [self internalActiveFingerprintForUsername:username accountName:accountName protocol:protocol];
    if(fingerprint && fingerprint->fingerprint) {
        otrl_privkey_hash_to_human(their_hash, fingerprint->fingerprint);
        fingerprintString = [NSString stringWithUTF8String:their_hash];
    }
    return fingerprintString;
    
}

- (BOOL)hasVerifiedFingerprintsForUsername:(NSString *)username
                               accountName:(NSString*)accountName
                                  protocol:(NSString *)protocol
{
    BOOL hasVerifiedFingerprints = NO;
    
    ConnContext *context = [self contextForUsername:username accountName:accountName protocol:protocol];
    if (context) {
        Fingerprint *currentFingerPrint = context->fingerprint_root.next;
        while (currentFingerPrint != NULL) {
            if (currentFingerPrint->trust) {
                if(otrl_context_is_fingerprint_trusted(currentFingerPrint)) {
                    hasVerifiedFingerprints = YES;
                }

            }
            currentFingerPrint = currentFingerPrint->next;
        }
    }
    
    return hasVerifiedFingerprints;
}

- (BOOL) activeFingerprintIsVerifiedForUsername:(NSString*)username accountName:(NSString*)accountName protocol:(NSString*) protocol
{
    BOOL verified = NO;
    Fingerprint * fingerprint = [self internalActiveFingerprintForUsername:username accountName:accountName protocol:protocol];
    
    if( fingerprint && fingerprint->trust)
    {
        if(otrl_context_is_fingerprint_trusted(fingerprint)) {
            verified = YES;
        }
    }
    
    
    
    return verified;
}

- (void)setActiveFingerprintVerificationForUsername:(NSString*)username
                                        accountName:(NSString*)accountName
                                           protocol:(NSString*)protocol
                                           verified:(BOOL)verified
{
    Fingerprint * fingerprint = [self internalActiveFingerprintForUsername:username accountName:accountName protocol:protocol];
    const char * newTrust = nil;
    if(verified) {
        newTrust = [@"verified" UTF8String];
    }
        
    if(fingerprint)
    {
        otrl_context_set_trust(fingerprint, newTrust);
        [self writeFingerprints];
    }
}

-(void)writeFingerprints
{
    FILE *storef;
    NSString *path = [self fingerprintsPath];
    storef = fopen([path UTF8String], "wb");
    if (!storef) return;
    otrl_privkey_write_fingerprints_FILEp(_userState, storef);
    fclose(storef);
}

- (OTRKitMessageState) messageStateForUsername:(NSString*)username accountName:(NSString*)accountName protocol:(NSString*) protocol {
    ConnContext *context = [self contextForUsername:username accountName:accountName protocol:protocol];
    OTRKitMessageState messageState = OTRKitMessageStatePlaintext;
    if (context) {
        switch (context->msgstate) {
            case OTRL_MSGSTATE_ENCRYPTED:
                messageState = OTRKitMessageStateEncrypted;
                break;
            case OTRL_MSGSTATE_FINISHED:
                messageState = OTRKitMessageStateFinished;
                break;
            case OTRL_MSGSTATE_PLAINTEXT:
                messageState = OTRKitMessageStatePlaintext;
                break;
            default:
                messageState = OTRKitMessageStatePlaintext;
                break;
        }
    }
    return messageState;
}

-(OTRKitPolicy)otrPolicy {
    if (_otrPolicy) {
        return _otrPolicy;
    }
    return OTRKitPolicyDefault;
}

-(OtrlPolicy)otrlPolicy {
    switch (self.otrPolicy) {
        case OTRKitPolicyDefault:
            return OTRL_POLICY_DEFAULT;
            break;
        case OTRKitPolicyAlways:
            return OTRL_POLICY_ALWAYS;
            break;
        case OTRKitPolicyManual:
            return OTRL_POLICY_MANUAL;
            break;
        case OTRKitPolicyOpportunistic:
            return OTRL_POLICY_OPPORTUNISTIC;
            break;
        case OTRKitPolicyNever:
            return OTRL_POLICY_NEVER;
            break;
        default:
            return OTRL_POLICY_DEFAULT;
            break;
    }
}

- (NSArray *)allFingerprints
{
    NSMutableArray * fingerprintsArray = [NSMutableArray array];
    ConnContext * context = _userState->context_root;
    while (context) {
        Fingerprint * fingerprint = context->fingerprint_root.next;
        while (fingerprint) {
            char their_hash[OTRL_PRIVKEY_FPRINT_HUMAN_LEN];
            otrl_privkey_hash_to_human(their_hash, fingerprint->fingerprint);
            NSString * fingerprintString = [NSString stringWithUTF8String:their_hash];
            NSString * username = [NSString stringWithUTF8String:fingerprint->context->username];
            NSString * accountName = [NSString stringWithUTF8String:fingerprint->context->accountname];
            NSString * protocol = [NSString stringWithUTF8String:fingerprint->context->protocol];
            BOOL trusted = otrl_context_is_fingerprint_trusted(fingerprint);
            
            [fingerprintsArray addObject:@{kOTRKitUsernameKey:username,
                                           kOTRKitAccountNameKey:accountName,
                                           kOTRKitFingerprintKey:fingerprintString,
                                           kOTRKitProtocolKey:protocol,
                                           kOTRKitTrustKey: @(trusted)}];
            fingerprint = fingerprint->next;
        }
        context = context->next;
    }
    
    if ([fingerprintsArray count]) {
        return [NSArray arrayWithArray:fingerprintsArray];
    }
    return nil;
}

- (BOOL)deleteFingerprint:(NSString *)fingerprintString
                 username:(NSString *)username
              accountName:(NSString *)accountName
                 protocol:(NSString *)protocol
{
    ConnContext * context = [self contextForUsername:username accountName:accountName protocol:protocol];
    BOOL stop = NO;
    Fingerprint * fingerprint = nil;
    Fingerprint * currentFingerprint = context->fingerprint_root.next;
    while (currentFingerprint && !stop) {
        char their_hash[OTRL_PRIVKEY_FPRINT_HUMAN_LEN];
        otrl_privkey_hash_to_human(their_hash, currentFingerprint->fingerprint);
        NSString * currentFingerprintString = [NSString stringWithUTF8String:their_hash];
        if ([currentFingerprintString isEqualToString:fingerprintString]) {
            fingerprint = currentFingerprint;
            stop = YES;
        }
        else {
            currentFingerprint = currentFingerprint->next;
        }
    }
    
    if (fingerprint != [self internalActiveFingerprintForUsername:username accountName:accountName protocol:protocol]) {
        //will not delete if it is the active fingerprint;
        otrl_context_forget_fingerprint(fingerprint, 0);
        [self writeFingerprints];
        return YES;
    }
    
    return NO;
}

@end