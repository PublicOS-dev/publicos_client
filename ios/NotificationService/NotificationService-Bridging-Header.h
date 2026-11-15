//
// NotificationService-Bridging-Header.h
//
// SQLCipher (pulled in transitively by the XMTP pod) ships its own sqlite3.h
// that shadows the iOS SDK's via HEADER_SEARCH_PATHS. That shadowing breaks
// `import SQLite3` (the system modulemap can no longer precompile against the
// SQLCipher headers). Including sqlite3.h via a bridging header exposes the
// C API directly to Swift — no module needed.
//

#import "sqlite3.h"
