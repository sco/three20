#import "Three20/TTURLCache.h"
#import <CommonCrypto/CommonDigest.h>
#import <QuartzCore/QuartzCore.h>

//////////////////////////////////////////////////////////////////////////////////////////////////
  
#define TT_SMALL_IMAGE_SIZE (50*50)
#define TT_MEDIUM_IMAGE_SIZE (130*97)
#define TT_LARGE_IMAGE_SIZE (600*400)

static NSString* kCacheDirPathName = @"Three20";

static TTURLCache* gSharedCache = nil;

//////////////////////////////////////////////////////////////////////////////////////////////////

@implementation TTURLCache

@synthesize disableDiskCache = _disableDiskCache, disableImageCache = _disableImageCache,
  cachePath = _cachePath, maxPixelCount = _maxPixelCount, invalidationAge = _invalidationAge;

//////////////////////////////////////////////////////////////////////////////////////////////////
// class public

+ (TTURLCache*)sharedCache {
  if (!gSharedCache) {
    gSharedCache = [[TTURLCache alloc] init];
  }
  return gSharedCache;
}

+ (void)setSharedCache:(TTURLCache*)cache {
  if (gSharedCache != cache) {
    [gSharedCache release];
    gSharedCache = [cache retain];
  }
}

+ (NSString*)defaultCachePath {
  NSArray* paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
  NSString* cachesPath = [paths objectAtIndex:0];
  NSString* cachePath = [cachesPath stringByAppendingPathComponent:kCacheDirPathName];
  NSFileManager* fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:cachesPath]) {
    [fm createDirectoryAtPath:cachesPath attributes:nil];
  }
  if (![fm fileExistsAtPath:cachePath]) {
    [fm createDirectoryAtPath:cachePath attributes:nil];
  }
  return cachePath;
}

//////////////////////////////////////////////////////////////////////////////////////////////////
// private

- (void)expireImagesFromMemory {
  while (_imageSortedList.count) {
    NSString* key = [_imageSortedList objectAtIndex:0];
    UIImage* image = [_imageCache objectForKey:key];
    // TTLOG(@"EXPIRING %@", key);

    _totalPixelCount -= image.size.width * image.size.height;
    [_imageCache removeObjectForKey:key];
    [_imageSortedList removeObjectAtIndex:0];
    
    if (_totalPixelCount <= _maxPixelCount) {
      break;
    }
  }
}

- (void)storeImage:(UIImage*)image forURL:(NSString*)url force:(BOOL)force {
  if (image && (force || !_disableImageCache)) {
    int pixelCount = image.size.width * image.size.height;
    if (force || pixelCount < TT_LARGE_IMAGE_SIZE) {
      _totalPixelCount += pixelCount;
      if (_totalPixelCount > _maxPixelCount && _maxPixelCount) {
        [self expireImagesFromMemory];
      }

      if (!_imageCache) {
        _imageCache = [[NSMutableDictionary alloc] init];
      }
      if (!_imageSortedList) {
        _imageSortedList = [[NSMutableArray alloc] init];
      }

      [_imageSortedList addObject:url];
      [_imageCache setObject:image forKey:url];
    }
  }
}

- (UIImage*)loadImageFromBundle:(NSString*)url {
  NSString* path = TTPathForBundleResource([url substringFromIndex:9]);
  NSData* data = [NSData dataWithContentsOfFile:path];
  return [UIImage imageWithData:data];
}

- (UIImage*)loadImageFromDocuments:(NSString*)url {
  NSString* path = TTPathForDocumentsResource([url substringFromIndex:12]);
  NSData* data = [NSData dataWithContentsOfFile:path];
  return [UIImage imageWithData:data];
}

- (NSString*)createTemporaryURL {
  static int temporaryURLIncrement = 0;
  return [NSString stringWithFormat:@"temp:%d", temporaryURLIncrement++];
}

//////////////////////////////////////////////////////////////////////////////////////////////////
// NSObject

- (id)init {
  if (self == [super init]) {
    _cachePath = [[TTURLCache defaultCachePath] retain];
    _imageCache = nil;
    _imageSortedList = nil;
    _totalLoading = 0;
    _disableDiskCache = NO;
    _disableImageCache = NO;
    _invalidationAge = TT_DEFAULT_CACHE_INVALIDATION_AGE;
    _maxPixelCount = (TT_SMALL_IMAGE_SIZE*20) + (TT_MEDIUM_IMAGE_SIZE*12);
    _totalPixelCount = 0;
    
    // XXXjoe Disabling the built-in cache may save memory but it also makes UIWebView slow
    // NSURLCache* sharedCache = [[NSURLCache alloc] initWithMemoryCapacity:0 diskCapacity:0
    // diskPath:nil];
    // [NSURLCache setSharedURLCache:sharedCache];
    // [sharedCache release];
  }
  return self;
}

- (void)dealloc {
  [_imageCache release];
  [_imageSortedList release];
  [_cachePath release];
  [super dealloc];
}

//////////////////////////////////////////////////////////////////////////////////////////////////
// public

- (NSString *)keyForURL:(NSString*)url {
  const char* str = [url UTF8String];
  unsigned char result[CC_MD5_DIGEST_LENGTH];
  CC_MD5(str, strlen(str), result);

  return [NSString stringWithFormat:
    @"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
    result[0], result[1], result[2], result[3], result[4], result[5], result[6], result[7],
    result[8], result[9], result[10], result[11], result[12], result[13], result[14], result[15]
  ];
}

- (NSString*)cachePathForURL:(NSString*)url {
  NSString* key = [self keyForURL:url];
  return [self cachePathForKey:key];
}

- (NSString*)cachePathForKey:(NSString*)key {
  return [_cachePath stringByAppendingPathComponent:key];
}

- (BOOL)hasDataForURL:(NSString*)url {
  NSString* filePath = [self cachePathForURL:url];
  NSFileManager* fm = [NSFileManager defaultManager];
  return [fm fileExistsAtPath:filePath];
}

- (NSData*)dataForURL:(NSString*)url {
  return [self dataForURL:url expires:0 timestamp:nil];
}

- (NSData*)dataForURL:(NSString*)url expires:(NSTimeInterval)expirationAge
    timestamp:(NSDate**)timestamp {
  NSString* key = [self keyForURL:url];
  return [self dataForKey:key expires:expirationAge timestamp:timestamp];
}

- (NSData*)dataForKey:(NSString*)key expires:(NSTimeInterval)expirationAge
    timestamp:(NSDate**)timestamp {
  NSString* filePath = [self cachePathForKey:key];
  NSFileManager* fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:filePath]) {
    NSDictionary* attrs = [fm attributesOfItemAtPath:filePath error:nil];
    NSDate* modified = [attrs objectForKey:NSFileModificationDate];
    if (expirationAge && [modified timeIntervalSinceNow] < -expirationAge) {
      return nil;
    }
    if (timestamp) {
      *timestamp = modified;
    }

    return [NSData dataWithContentsOfFile:filePath];
  }

  return nil;
}

- (id)imageForURL:(NSString*)url {
  return [self imageForURL:url fromDisk:YES];
}

- (id)imageForURL:(NSString*)url fromDisk:(BOOL)fromDisk {
  UIImage* image = [_imageCache objectForKey:url];
  if (!image && fromDisk) {
    if (TTIsBundleURL(url)) {
      image = [self loadImageFromBundle:url];
      [self storeImage:image forURL:url];
    } else if (TTIsDocumentsURL(url)) {
      image = [self loadImageFromDocuments:url];
      [self storeImage:image forURL:url];
    }
  }
  return image;
}

- (void)storeData:(NSData*)data forURL:(NSString*)url {
  NSString* key = [self keyForURL:url];
  [self storeData:data forKey:key];
}

- (void)storeData:(NSData*)data forKey:(NSString*)key {
  if (!_disableDiskCache) {
    NSString* filePath = [self cachePathForKey:key];
    NSFileManager* fm = [NSFileManager defaultManager];
    [fm createFileAtPath:filePath contents:data attributes:nil];
  }
}

- (void)storeImage:(UIImage*)image forURL:(NSString*)url {
  [self storeImage:image forURL:url force:NO];
}
  
- (NSString*)storeTemporaryData:(NSData*)data {
  NSString* url = [self createTemporaryURL];
  [self storeData:data forURL:url];
  return url;
}

- (NSString*)storeTemporaryImage:(UIImage*)image toDisk:(BOOL)toDisk {
  NSString* url = [self createTemporaryURL];
  [self storeImage:image forURL:url force:YES];
  
  NSData* data = UIImagePNGRepresentation(image);
  [self storeData:data forURL:url];
  return url;
}

- (void)moveDataForURL:(NSString*)oldURL toURL:(NSString*)newURL {
  NSString* oldKey = [self keyForURL:oldURL];
  NSString* newKey = [self keyForURL:newURL];
  id image = [self imageForURL:oldKey];
  if (image) {
    [_imageSortedList removeObject:oldKey];
    [_imageCache removeObjectForKey:oldKey];
    [_imageSortedList addObject:newKey];
    [_imageCache setObject:image forKey:newKey];
  }
  NSString* oldPath = [self cachePathForURL:oldKey];
  NSFileManager* fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:oldPath]) {
    NSString* newPath = [self cachePathForURL:newKey];
    [fm moveItemAtPath:oldPath toPath:newPath error:nil];
  }
}

- (void)removeURL:(NSString*)url fromDisk:(BOOL)fromDisk {
  NSString*  key = [self keyForURL:url];
  [_imageSortedList removeObject:key];
  [_imageCache removeObjectForKey:key];
  
  if (fromDisk) {
    NSString* filePath = [self cachePathForKey:key];
    NSFileManager* fm = [NSFileManager defaultManager];
    if (filePath && [fm fileExistsAtPath:filePath]) {
      [fm removeItemAtPath:filePath error:nil];
    }
  }
}

- (void)removeKey:(NSString*)key {
  NSString* filePath = [self cachePathForKey:key];
  NSFileManager* fm = [NSFileManager defaultManager];
  if (filePath && [fm fileExistsAtPath:filePath]) {
    [fm removeItemAtPath:filePath error:nil];
  }
}

- (void)removeAll:(BOOL)fromDisk {
  [_imageCache removeAllObjects];
  [_imageSortedList removeAllObjects];
  _totalPixelCount = 0;

  if (fromDisk) {
    NSFileManager* fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:_cachePath error:nil];
    [fm createDirectoryAtPath:_cachePath attributes:nil];
  }
}

- (void)invalidateURL:(NSString*)url {
  NSString* key = [self keyForURL:url];
  return [self invalidateKey:key];
}

- (void)invalidateKey:(NSString*)key {
  NSString* filePath = [self cachePathForKey:key];
  NSFileManager* fm = [NSFileManager defaultManager];
  if (filePath && [fm fileExistsAtPath:filePath]) {
    NSDate* invalidDate = [NSDate dateWithTimeIntervalSinceNow:-_invalidationAge];
    NSDictionary* attrs = [NSDictionary dictionaryWithObject:invalidDate
      forKey:NSFileModificationDate];

    [fm changeFileAttributes:attrs atPath:filePath];
  }
}

- (void)invalidateAll {
  NSDate* invalidDate = [NSDate dateWithTimeIntervalSinceNow:-_invalidationAge];
  NSDictionary* attrs = [NSDictionary dictionaryWithObject:invalidDate
    forKey:NSFileModificationDate];

  NSFileManager* fm = [NSFileManager defaultManager];
  NSDirectoryEnumerator* e = [fm enumeratorAtPath:_cachePath];
  for (NSString* fileName; fileName = [e nextObject]; ) {
    NSString* filePath = [_cachePath stringByAppendingPathComponent:fileName];
    [fm changeFileAttributes:attrs atPath:filePath];
  }
}

- (void)logMemoryUsage {
  TTLOG(@"======= IMAGE CACHE: %d images, %d pixels ========", _imageCache.count, _totalPixelCount);
  NSEnumerator* e = [_imageCache keyEnumerator];
  for (NSString* key ; key = [e nextObject]; ) {
    UIImage* image = [_imageCache objectForKey:key];
    TTLOG(@"  %f x %f %@", image.size.width, image.size.height, key);
  }  
}

@end
