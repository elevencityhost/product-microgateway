// Copyright (c) 2020, WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
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

import ballerina/runtime;
import ballerina/jwt;
import ballerina/http;

boolean jwtGeneratorClassLoaded = loadJWTGeneratorImpl();
boolean claimRetrieverClassLoaded = loadClaimRetrieverImpl();

# Setting backend JWT header when there is no JWT Token is present.
#
# + req - The `Request` instance.
# + cacheKey - key for the jwt generator cache
# + enabledCaching - jwt generator caching enabled
# + generatedToken - generated Backend JWT
# + return - Returns `true` if the token generation and setting the header completed successfully
function setGeneratedTokenAsHeader(http:Request req,
                                string cacheKey,
                                boolean enabledCaching,
                                handle | error generatedToken)
                                returns @tainted boolean {

    if (generatedToken is error) {
        printError(KEY_JWT_AUTH_PROVIDER, "Token not generated due to error", generatedToken);
        return false;
    }
    printDebug(KEY_JWT_AUTH_PROVIDER, "Generated jwt token");
    printDebug(KEY_JWT_AUTH_PROVIDER, "Token: " + generatedToken.toString());

    if (enabledCaching) {
        error? err = jwtGeneratorCache.put(<@untainted>cacheKey, <@untainted>generatedToken.toString());
        if (err is error) {
            printError(KEY_JWT_AUTH_PROVIDER, "Error while adding entry to jwt generator cache", err);
        }
        printDebug(KEY_JWT_AUTH_PROVIDER, "Added to jwt generator token cache.");
    }
    req.setHeader(jwtheaderName, generatedToken.toString());
    return true;
}

# populate and return ClaimsMapDTO object which is required to the further processing of Jwt generator implementation.
#
# + authContext - Authentication Context
# + remoteUserClaimRetrievalEnabled - true if remoteUserClaimRetrieval is enabled
# + issuer - Issuer (for Opaque token flow)
# + payload - For the jwt, payload of the decoded jwt
# + return - ClaimsMapDTO
function createMapFromRetrievedUserClaimsListDTO(AuthenticationContext authContext, 
                                                    boolean remoteUserClaimRetrievalEnabled,
                                                    string? issuer,
                                                    jwt:JwtPayload? payload = ())
                                                    returns @tainted ClaimsMapDTO {
    ClaimsMapDTO claimsMapDTO = {};
    CustomClaimsMapDTO customClaimsMapDTO = {};
    UserClaimRetrieverContextDTO? userInfo = ();
    if (payload is ()) {
        //if payload is empty, this is from oauth2 flow
        runtime:InvocationContext invocationContext = runtime:getInvocationContext();
        runtime:Principal? principal = invocationContext?.principal;
        if (principal is runtime:Principal) {
            string[]? scopes = principal?.scopes;
            if (scopes is string[]) {
                string concatenatedScope = "";
                foreach string scope in scopes {
                    concatenatedScope += scope + " ";
                }
                customClaimsMapDTO["scope"] = concatenatedScope.trim();
            }
            userInfo = generateUserClaimRetrieverContextFromPrincipal(authContext, principal, issuer);
        } else {
            printDebug(JWT_GEN_UTIL, "Claim retrieval implementation is not executed due to the unavailability " +
                            "of the principal component");
        }
        claimsMapDTO.iss = issuer ?: UNKNOWN_VALUE;
    } else  {
        string? iss = payload?.iss;
        if (iss is string) {
            claimsMapDTO.iss = iss;
        }
        map<json>? customClaims = payload?.customClaims;
        if (customClaims is map<json>) {
            foreach var [key, value] in customClaims.entries() {
                string | error claimValue = trap <string> value;
                if (claimValue is string) {
                    customClaimsMapDTO[key] = claimValue;
                }
            }
        }
        userInfo = generateUserClaimRetrieverContextFromJWT(authContext, payload);
    }

    if (remoteUserClaimRetrievalEnabled) {
        RetrievedUserClaimsListDTO ? claimsListDTO = retrieveClaims(userInfo);
        if (claimsListDTO is RetrievedUserClaimsListDTO) {
            ClaimDTO[] claimList = claimsListDTO.list;
            foreach ClaimDTO claim in claimList {
                customClaimsMapDTO[claim.uri] = claim.value;
            }
        }
    }

    ApplicationClaimsMapDTO applicationClaimsMapDTO = {};
    applicationClaimsMapDTO.id = emptyStringIfUnknownValue(authContext.applicationId);
    applicationClaimsMapDTO.owner = emptyStringIfUnknownValue(authContext.subscriber);
    applicationClaimsMapDTO.name = emptyStringIfUnknownValue(authContext.applicationName);
    applicationClaimsMapDTO.tier = emptyStringIfUnknownValue(authContext.applicationTier);

    customClaimsMapDTO.application = applicationClaimsMapDTO;
    claimsMapDTO.sub = emptyStringIfUnknownValue(authContext.username);
    claimsMapDTO.customClaims = customClaimsMapDTO;
    return claimsMapDTO;
}

# Populate Map to keep API related information for JWT generation process
#
# + invocationContext - ballerina runtime invocationContext
# + return - String map with the properties: apiName, apiVersion, apiTier, apiContext, apiPublisher and
#               subscriberTenantDomain
function createAPIDetailsMap (runtime:InvocationContext invocationContext) returns map<string> {
    map<string> apiDetails = {};
    AuthenticationContext authenticationContext = <AuthenticationContext>invocationContext.attributes[AUTHENTICATION_CONTEXT];
    APIConfiguration? apiConfig = apiConfigAnnotationMap[<string>invocationContext.attributes[http:SERVICE_NAME]];
    if (apiConfig is APIConfiguration) {
        apiDetails["apiName"] = apiConfig.name;
        apiDetails["apiVersion"] = apiConfig.apiVersion;
        apiDetails["apiTier"] = (apiConfig.apiTier != "") ? apiConfig.apiTier : UNLIMITED_TIER;
        apiDetails["apiContext"] = <string> invocationContext.attributes[API_CONTEXT];
        apiDetails["apiPublisher"] = apiConfig.publisher;
        apiDetails["subscriberTenantDomain"] = authenticationContext.subscriberTenantDomain;
    }
    return apiDetails;
}

function emptyStringIfUnknownValue (string value) returns string {
    return value != UNKNOWN_VALUE ? value : "";
}

public function loadJWTGeneratorImpl() returns boolean {
    boolean enabledJWTGenerator = getConfigBooleanValue(JWT_GENERATOR_ID,
                                                        JWT_GENERATOR_ENABLED,
                                                        DEFAULT_JWT_GENERATOR_ENABLED);
    if (enabledJWTGenerator) {
        string generatorClass = getConfigValue(JWT_GENERATOR_ID,
                                                JWT_GENERATOR_IMPLEMENTATION,
                                                DEFAULT_JWT_GENERATOR_IMPLEMENTATION);
        string dialectURI = getConfigValue(JWT_GENERATOR_ID,
                                            JWT_GENERATOR_DIALECT,
                                            DEFAULT_JWT_GENERATOR_DIALECT);
        string signatureAlgorithm = getConfigValue(JWT_GENERATOR_ID,
                                                    JWT_GENERATOR_SIGN_ALGO,
                                                    DEFAULT_JWT_GENERATOR_SIGN_ALGO);
        string certificateAlias = getConfigValue(JWT_GENERATOR_ID,
                                                    JWT_GENERATOR_CERTIFICATE_ALIAS,
                                                    DEFAULT_JWT_GENERATOR_CERTIFICATE_ALIAS);
        string privateKeyAlias = getConfigValue(JWT_GENERATOR_ID,
                                                JWT_GENERATOR_PRIVATE_KEY_ALIAS,
                                                DEFAULT_JWT_GENERATOR_PRIVATE_KEY_ALIAS);
        int tokenExpiry = getConfigIntValue(JWT_GENERATOR_ID,
                                                JWT_GENERATOR_TOKEN_EXPIRY,
                                                DEFAULT_JWT_GENERATOR_TOKEN_EXPIRY);
        any[] restrictedClaims = getConfigArrayValue(JWT_GENERATOR_ID,
                                                    JWT_GENERATOR_RESTRICTED_CLAIMS);
        string keyStoreLocationUnresolved = getConfigValue(LISTENER_CONF_INSTANCE_ID,
                                                            KEY_STORE_PATH,
                                                            DEFAULT_KEY_STORE_PATH);
        string keyStorePassword = getConfigValue(LISTENER_CONF_INSTANCE_ID,
                                                                KEY_STORE_PASSWORD,
                                                                DEFAULT_KEY_STORE_PASSWORD);
        string tokenIssuer = getConfigValue(JWT_GENERATOR_ID,
                                            JWT_GENERATOR_TOKEN_ISSUER,
                                            DEFAULT_JWT_GENERATOR_TOKEN_ISSUER);
        any[] tokenAudience = getConfigArrayValue(JWT_GENERATOR_ID,
                                                    JWT_GENERATOR_TOKEN_AUDIENCE);
        // provide backward compatibility for skew time
        int skewTime = getConfigIntValue(SERVER_CONF_ID,
                                            SERVER_TIMESTAMP_SKEW,
                                            DEFAULT_SERVER_TIMESTAMP_SKEW);
        if (skewTime == DEFAULT_SERVER_TIMESTAMP_SKEW) {
            skewTime = getConfigIntValue(KM_CONF_INSTANCE_ID,
                                            TIMESTAMP_SKEW,
                                            DEFAULT_TIMESTAMP_SKEW);
        }
        boolean enabledCaching = getConfigBooleanValue(JWT_GENERATOR_CACHING_ID,
                                                        JWT_GENERATOR_TOKEN_CACHE_ENABLED,
                                                        DEFAULT_JWT_GENERATOR_TOKEN_CACHE_ENABLED);
        int cacheExpiry = getConfigIntValue(JWT_GENERATOR_CACHING_ID,
                                                JWT_GENERATOR_TOKEN_CACHE_EXPIRY,
                                                DEFAULT_TOKEN_CACHE_EXPIRY);

        return loadJWTGeneratorClass(generatorClass,
                                    dialectURI,
                                    signatureAlgorithm,
                                    keyStoreLocationUnresolved,
                                    keyStorePassword,
                                    certificateAlias,
                                    privateKeyAlias,
                                    tokenExpiry,
                                    restrictedClaims,
                                    enabledCaching,
                                    cacheExpiry,
                                    tokenIssuer,
                                    tokenAudience);
    }
    return false;
}
