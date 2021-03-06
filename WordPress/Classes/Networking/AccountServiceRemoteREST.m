#import "AccountServiceRemoteREST.h"
#import "WordPressComApi.h"
#import "RemoteBlog.h"
#import "RemoteBlogOptionsHelper.h"
#import "Constants.h"
#import "WPAccount.h"
#import "WordPress-Swift.h"

static NSString * const UserDictionaryIDKey = @"ID";
static NSString * const UserDictionaryUsernameKey = @"username";
static NSString * const UserDictionaryEmailKey = @"email";
static NSString * const UserDictionaryDisplaynameKey = @"display_name";
static NSString * const UserDictionaryPrimaryBlogKey = @"primary_blog";
static NSString * const UserDictionaryAvatarURLKey = @"avatar_URL";
static NSString * const UserDictionaryDateKey = @"date";

@interface AccountServiceRemoteREST ()
@property (nonatomic, strong) WordPressComApi *anonymousApi;
@end

@implementation AccountServiceRemoteREST

- (void)getBlogsWithSuccess:(void (^)(NSArray *))success
                    failure:(void (^)(NSError *))failure
{
    NSString *requestUrl = [self pathForEndpoint:@"me/sites"
                                     withVersion:ServiceRemoteRESTApiVersion_1_1];
    
    [self.api GET:requestUrl
       parameters:nil
          success:^(AFHTTPRequestOperation *operation, id responseObject) {
              if (success) {
                  success([self remoteBlogsFromJSONArray:responseObject[@"sites"]]);
              }
          } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
              if (failure) {
                  failure(error);
              }
          }];
}

- (void)getDetailsForAccount:(WPAccount *)account
                     success:(void (^)(RemoteUser *remoteUser))success
                     failure:(void (^)(NSError *error))failure
{
    // IMPORTANT: We're adding this assertion even though the account is not used here to let the
    // caller know this parameter needs to be set (following the documentation of the protocol).
    // This parameter is used and required by the XMLRPC variant of this method.
    //
    NSParameterAssert([account isKindOfClass:[WPAccount class]]);
    
    NSString *requestUrl = [self pathForEndpoint:@"me"
                                     withVersion:ServiceRemoteRESTApiVersion_1_1];
    
    [self.api GET:requestUrl
       parameters:nil
          success:^(AFHTTPRequestOperation *operation, NSDictionary *responseObject) {
              if (!success) {
                  return;
              }
              RemoteUser *remoteUser = [self remoteUserFromDictionary:responseObject];
              success(remoteUser);
          }
          failure:^(AFHTTPRequestOperation *operation, NSError *error) {
              if (failure) {
                  failure(error);
              }
          }];
}

- (void)updateBlogsVisibility:(NSDictionary *)blogs
                      success:(void (^)())success
                      failure:(void (^)(NSError *))failure
{
    NSParameterAssert([blogs isKindOfClass:[NSDictionary class]]);

    /*
     The `POST me/sites` endpoint expects it's input in a format like:
     @{
       @"sites": @[
         @"1234": {
           @"visible": @YES
         },
         @"2345": {
           @"visible": @NO
         },
       ]
     }
     */
    NSMutableDictionary *sites = [NSMutableDictionary dictionaryWithCapacity:blogs.count];
    [blogs enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        NSParameterAssert([key isKindOfClass:[NSNumber class]]);
        NSParameterAssert([obj isKindOfClass:[NSNumber class]]);
        /*
         Blog IDs are pased as strings because JSON dictionaries can't take
         non-string keys. If you try, you get a NSInvalidArgumentException
         */
        NSString *blogID = [key stringValue];
        sites[blogID] = @{ @"visible": obj };
    }];

    NSDictionary *parameters = @{
                                 @"sites": sites,
                                 };
    NSString *path = [self pathForEndpoint:@"me/sites"
                               withVersion:ServiceRemoteRESTApiVersion_1_1];
    [self.api POST:path
        parameters:parameters
           success:^(AFHTTPRequestOperation *operation, id responseObject) {
               if (success) {
                   success();
               }
           } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
               if (failure) {
                   failure(error);
               }
           }];
}

- (WordPressComApi *)anonymousApi
{
    if (!_anonymousApi) {
        _anonymousApi = [WordPressComApi anonymousApi];
    }

    return _anonymousApi;
}

- (void)isEmailAvailable:(NSString *)email success:(void (^)(BOOL available))success failure:(void (^)(NSError *error))failure
{
    // TODO: (Aerych 2016-04) We need to make a versioned flavor of this endpoint
    // and ensure it always returns a JSON object. See 7724 in the relevant trac.
    // Remove the special case in `WordPressComApi.assertApiVersion` once the
    // endpoint is versioned.
    NSString *path = @"https://public-api.wordpress.com/is-available/email";
    [self.api GET:path
       parameters:@{ @"q": email }
          success:^(AFHTTPRequestOperation *operation, id responseObject) {
              if (!success) {
                  return;
              }

              // If the email address is not available (has already been used)
              // the endpoint will reply with a 200 status code and an JSON
              // object describing an error.
              // The error is that the queried email address is not available,
              // which is our failure case. Test the error response for the
              // "taken" reason to confirm the email address exists.
              BOOL available = NO;
              if ([responseObject isKindOfClass:[NSDictionary class]]) {
                  NSDictionary *dict = (NSDictionary *)responseObject;
                  NSString *errStr = [dict stringForKey:@"error"];
                  available = ![@"taken" isEqualToString:errStr];
              }

              success(available);

          } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
              // The is-available endpoint is an oddball.
              // Rather than returning a proper JSON object it can return a simple
              // string, which is subsequently evaluated as an error condition.
              // A response of "true" means that the queried email address was available,
              // which is our success case.
              if ([operation.responseString isEqualToString:@"true"]) {
                  if (success) {
                      success(YES);
                  }
                  return;
              }
              if (failure) {
                  failure(error);
              }
          }];
}

- (void)requestWPComAuthLinkForEmail:(NSString *)email success:(void (^)())success failure:(void (^)(NSError *error))failure
{
    NSAssert([email length] > 0, @"Needs an email address.");

    NSString *path = [self pathForEndpoint:@"auth/send-login-email"
                                     withVersion:ServiceRemoteRESTApiVersion_1_1];

    [self.api POST:path
        parameters:@{
                     @"email": email,
                     @"client_id": [ApiCredentials client],
                     @"client_secret": [ApiCredentials secret],
                     }
           success:^(AFHTTPRequestOperation *operation, id responseObject) {
               if (success) {
                   success();
               }
           } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
               if (failure) {
                   failure(error);
               }
           }];
}


#pragma mark - Private Methods

- (RemoteUser *)remoteUserFromDictionary:(NSDictionary *)dictionary
{
    RemoteUser *remoteUser = [RemoteUser new];
    remoteUser.userID = [dictionary numberForKey:UserDictionaryIDKey];
    remoteUser.username = [dictionary stringForKey:UserDictionaryUsernameKey];
    remoteUser.email = [dictionary stringForKey:UserDictionaryEmailKey];
    remoteUser.displayName = [dictionary stringForKey:UserDictionaryDisplaynameKey];
    remoteUser.primaryBlogID = [dictionary numberForKey:UserDictionaryPrimaryBlogKey];
    remoteUser.avatarURL = [dictionary stringForKey:UserDictionaryAvatarURLKey];
    remoteUser.dateCreated = [NSDate dateWithISO8601String:[dictionary stringForKey:UserDictionaryDateKey]];
    
    return remoteUser;
}

- (NSArray *)remoteBlogsFromJSONArray:(NSArray *)jsonBlogs
{
    NSArray *blogs = jsonBlogs;
    return [blogs wp_map:^id(NSDictionary *jsonBlog) {
        return [self remoteBlogFromJSONDictionary:jsonBlog];
    }];
}

- (RemoteBlog *)remoteBlogFromJSONDictionary:(NSDictionary *)jsonBlog
{
    RemoteBlog *blog = [RemoteBlog new];
    blog.blogID =  [jsonBlog numberForKey:@"ID"];
    blog.name = [jsonBlog stringForKey:@"name"];
    blog.tagline = [jsonBlog stringForKey:@"description"];
    blog.url = [jsonBlog stringForKey:@"URL"];
    blog.xmlrpc = [jsonBlog stringForKeyPath:@"meta.links.xmlrpc"];
    blog.jetpack = [[jsonBlog numberForKey:@"jetpack"] boolValue];
    blog.icon = [jsonBlog stringForKeyPath:@"icon.img"];
    blog.capabilities = [jsonBlog dictionaryForKey:@"capabilities"];
    blog.isAdmin = [[jsonBlog numberForKeyPath:@"capabilities.manage_options"] boolValue];
    blog.visible = [[jsonBlog numberForKey:@"visible"] boolValue];
    blog.options = [RemoteBlogOptionsHelper mapOptionsFromResponse:jsonBlog];
    blog.planID = [jsonBlog numberForKeyPath:@"plan.product_id"];
    return blog;
}

@end
