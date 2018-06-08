// Copyright (c)  WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file   except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/http;
import ballerina/log;
import ballerina/auth;
import ballerina/config;
import ballerina/runtime;
import ballerina/system;
import ballerina/time;
import ballerina/io;
import ballerina/reflect;


// Authentication filter

@Description {value:"Representation of the Authentication filter"}
@Field {value:"filterRequest: request filter method which attempts to authenticated the request"}
public type AuthnFilter object {

    public {
        OAuthnAuthenticator oauthnHandler;// Handles the oauth2 authentication;
        http:AuthnHandlerChain authnHandlerChain;
    }

    public new (oauthnHandler, authnHandlerChain) {}

    @Description {value:"filterRequest: Request filter function"}
    public function filterRequest (http:Request request, http:FilterContext context) returns http:FilterResult {
        //Setting UUID
        context.attributes[MESSAGE_ID] = system:uuid();
        context.attributes[FILTER_FAILED] = false;
        // get auth config for this resource
        boolean authenticated;
        APIRequestMetaDataDto apiKeyValidationRequestDto = getKeyValidationRequestObject(context);
        var (isSecured, authProviders) = getResourceAuthConfig(context);
        APIKeyValidationDto apiKeyValidationDto;
        AuthenticationContext authenticationContext;
        boolean isAuthorized;
        if (isSecured) {
            string authHeader;
            string authHeaderName = getAuthorizationHeader(reflect:getServiceAnnotations(context.serviceType));
            if (request.hasHeader(authHeaderName)) {
                authHeader = request.getHeader(authHeaderName);
            } else {
                log:printError("No authorization header was provided");
                return createFilterResult(false, 401, "No authorization header was provided");
            }
            string providerId = getAuthenticationProviderType(request.getHeader(authHeaderName));
            // if auth providers are there, use those to authenticate
            if(providerId != AUTH_SCHEME_OAUTH2) {
                string[] providerIds = [providerId];
                isAuthorized = self.authnHandlerChain.handleWithSpecificAuthnHandlers(providerIds, request);
            } else {
                match extractAccessToken(request) {
                    string token => {
                        apiKeyValidationRequestDto.accessToken = token;
                        match self.oauthnHandler.handle(request, apiKeyValidationRequestDto) {
                            APIKeyValidationDto apiKeyValidationDto => {
                                isAuthorized = <boolean>apiKeyValidationDto.authorized;
                                if(isAuthorized) {
                                    authenticationContext.authenticated = true;
                                    authenticationContext.tier = apiKeyValidationDto.tier;
                                    authenticationContext.apiKey = token;
                                    if (apiKeyValidationDto.endUserName != "") {
                                        authenticationContext.username = apiKeyValidationDto.endUserName;
                                    } else {
                                        authenticationContext.username = END_USER_ANONYMOUS;
                                    }
                                    authenticationContext.apiPublisher = apiKeyValidationDto.apiPublisher;
                                    authenticationContext.keyType = apiKeyValidationDto.keyType;
                                    authenticationContext.callerToken = apiKeyValidationDto.endUserToken;
                                    authenticationContext.applicationId = apiKeyValidationDto.applicationId;
                                    authenticationContext.applicationName = apiKeyValidationDto.applicationName;
                                    authenticationContext.applicationTier = apiKeyValidationDto.applicationTier;
                                    authenticationContext.subscriber = apiKeyValidationDto.subscriber;
                                    authenticationContext.consumerKey = apiKeyValidationDto.consumerKey;
                                    authenticationContext.apiTier = apiKeyValidationDto.apiTier;
                                    authenticationContext.subscriberTenantDomain = apiKeyValidationDto.subscriberTenantDomain;
                                    authenticationContext.spikeArrestLimit = check <int> apiKeyValidationDto.spikeArrestLimit;
                                    authenticationContext.spikeArrestUnit = apiKeyValidationDto.spikeArrestUnit;
                                    authenticationContext.stopOnQuotaReach = <boolean>apiKeyValidationDto.stopOnQuotaReach;
                                    authenticationContext.isContentAwareTierPresent = <boolean> apiKeyValidationDto
                                    .contentAware;
                                    authenticationContext.callerToken = apiKeyValidationDto.endUserToken;
                                    if(getConfigBooleanValue(JWT_CONFIG_INSTANCE_ID, JWT_ENABLED, false) &&
                                        authenticationContext.callerToken != "") {
                                        string jwtheaderName = getConfigValue(JWT_CONFIG_INSTANCE_ID, JWT_HEADER,
                                            JWT_HEADER_NAME);
                                        request.setHeader(jwtheaderName, authenticationContext.callerToken);
                                    }
                                    context.attributes[AUTHENTICATION_CONTEXT] = authenticationContext;
                                    runtime:AuthContext authContext = runtime:getInvocationContext().authContext;
                                    authContext.scheme = AUTH_SCHEME_OAUTH2;
                                    authContext.authToken = token;
                                } else {
                                    int status = check <int> apiKeyValidationDto.validationStatus;
                                    setErrorMessageToFilterContext(context, status);
                                    return createFilterResult(true, 200, "Authentication filter has failed. But
                                    continuing in order to  provide error details");
                                }
                            }
                            error err => {
                                log:printError(err.message, err = err);
                                setErrorMessageToFilterContext(context, API_AUTH_GENERAL_ERROR);
                                return createFilterResult(true, 200, "Authentication filter has failed. But
                                    continuing in order to  provide error details");
                            }
                        }
                    }
                    error err => {
                        log:printError(err.message, err = err);
                        setErrorMessageToFilterContext(context, API_AUTH_GENERAL_ERROR);
                        return createFilterResult(true, 200, "Authentication filter has failed. But
                                    continuing in order to  provide error details");
                    }
                }
            }

        } else {
            // not secured, no need to authenticate
            string clientIp = getClientIp(request);
            authenticationContext.authenticated = true;
            authenticationContext.tier = UNAUTHENTICATED_TIER;
            authenticationContext.stopOnQuotaReach = true;
            authenticationContext.apiKey = clientIp ;
            authenticationContext.username = END_USER_ANONYMOUS;
            authenticationContext.applicationId = clientIp;
            authenticationContext.keyType = PRODUCTION_KEY_TYPE;
            context.attributes[AUTHENTICATION_CONTEXT] = authenticationContext;
            return createFilterResult(true, 200 , "Successfully authenticated");
        }
        return createAuthnResult(isAuthorized);
    }
};


@Description {value:"Checks if the resource is secured"}
@Param {value:"context: FilterContext object"}
@Return {value:"boolean, string[]: tuple of whether the resource is secured and the list of auth provider ids "}
function getResourceAuthConfig (http:FilterContext context) returns (boolean, string[]) {
    boolean resourceSecured;
    string[] authProviderIds = [];
    // get authn details from the resource level
    http:ListenerAuthConfig? resourceLevelAuthAnn = getAuthAnnotation(ANN_PACKAGE,
    RESOURCE_ANN_NAME,
    reflect:getResourceAnnotations(context.serviceType, context.resourceName));
    http:ListenerAuthConfig? serviceLevelAuthAnn = getAuthAnnotation(ANN_PACKAGE,
    SERVICE_ANN_NAME,
    reflect:getServiceAnnotations(context.serviceType));
    // check if authentication is enabled
    resourceSecured = isResourceSecured(resourceLevelAuthAnn, serviceLevelAuthAnn);
    // if resource is not secured, no need to check further
    if (!resourceSecured) {
        return (resourceSecured, authProviderIds);
    }
    // check if auth providers are given at resource level
    match resourceLevelAuthAnn.authProviders {
        string[] providers => {
            authProviderIds = providers;
        }
        () => {
            // no auth providers found in resource level, try in service level
            match serviceLevelAuthAnn.authProviders {
                string[] providers => {
                    authProviderIds = providers;
                }
                () => {
                    // no auth providers found
                }
            }
        }
    }
    return (resourceSecured, authProviderIds);
}

function getAuthenticationProviderType(string authHeader) returns (string) {
    if(authHeader.contains(AUTH_SCHEME_BASIC)){
        return AUTHN_SCHEME_BASIC;
    } else if (authHeader.contains(AUTH_SCHEME_BEARER) && authHeader.contains(".")) {
        return AUTH_SCHEME_JWT;
    } else {
        return AUTH_SCHEME_OAUTH2;
    }
}


