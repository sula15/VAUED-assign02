// main.bal - Complete URL Shortener Service
import ballerina/http;
import ballerina/io;
import ballerina/time;
import ballerina/crypto;
import ballerina/lang.array;
import ballerina/observe;
import ballerinax/prometheus as _;

// Service configuration
configurable int port = 8080;

//=============================================================================
// DATA MODELS
//=============================================================================

// URL mapping record
type UrlMapping record {
    string shortCode;
    string longUrl;
    int clickCount;
    string createdAt;
};

// In-memory storage for simplicity
map<UrlMapping> urlDatabase = {};

//=============================================================================
// METRICS CONFIGURATION
//=============================================================================

// Define metrics to track
final observe:Counter urlCreationCounter = new("url_creation_total", 
    "Total number of URLs shortened");
    
final observe:Counter urlRedirectCounter = new("url_redirect_total", 
    "Total number of URL redirects");
    
final observe:Gauge activeUrlsGauge = new("active_urls",
    "Number of active shortened URLs");

//=============================================================================
// MAIN SERVICE
//=============================================================================

// Main service
service / on new http:Listener(port) {
    // Health check endpoint
    resource function get health() returns json {
        return {"status": "UP"};
    }
    
    // Resource for creating a short URL
    resource function post shorten(@http:Payload json payload) returns json|error {
        // Validate input
        json|error urlValue = payload.url;
        
        if urlValue is error {
            return error("URL is required");
        }
        
        string longUrl = urlValue.toString();
        
        // Validate URL format (basic check)
        if !longUrl.startsWith("http://") && !longUrl.startsWith("https://") {
            return error("Invalid URL format. URL must start with http:// or https://");
        }
        
        // Check if URL already exists in our database
        foreach var [code, mapping] in urlDatabase.entries() {
            if mapping.longUrl == longUrl {
                // URL already exists, return existing short code
                return {
                    "shortCode": mapping.shortCode,
                    "shortUrl": "http://localhost:" + port.toString() + "/" + mapping.shortCode,
                    "longUrl": mapping.longUrl,
                    "note": "This URL was already shortened"
                };
            }
        }
        
        // Generate short code
        string shortCode = generateShortCode(longUrl);
        
        // Ensure uniqueness by checking if code exists
        while urlDatabase.hasKey(shortCode) {
            // If collision, append a character and rehash
            shortCode = generateShortCode(longUrl + shortCode);
        }
        
        // Save URL mapping
        UrlMapping mapping = saveUrl(shortCode, longUrl);
        
        // Record metrics
        recordUrlCreation();
        
        // Return response
        return {
            "shortCode": shortCode,
            "shortUrl": "http://localhost:" + port.toString() + "/" + shortCode,
            "longUrl": longUrl
        };
    }
    
    // Resource for redirecting from short URL to original URL
    resource function get [string shortCode]() returns http:Response|error {
        UrlMapping? mapping = getUrl(shortCode);
        
        http:Response response = new;
        
        if mapping is UrlMapping {
            // Increment click count
            incrementClickCount(shortCode);
            
            // Record metrics
            recordUrlRedirect(shortCode);
            
            // Redirect to the original URL
            response.statusCode = 302; // Redirect
            response.setHeader("Location", mapping.longUrl);
        } else {
            response.statusCode = 404;
            response.setPayload("Short URL not found");
        }
        
        return response;
    }
    
    // Resource for getting statistics about a URL
    resource function get stats/[string shortCode]() returns json|error {
        UrlMapping? mappingResult = getUrl(shortCode);
        
        if mappingResult is UrlMapping {
            return {
                "shortCode": mappingResult.shortCode,
                "longUrl": mappingResult.longUrl,
                "clicks": mappingResult.clickCount,
                "createdAt": mappingResult.createdAt
            };
        } else {
            return error("Short URL not found");
        }
    }
    
    // Resource for listing all URLs
    resource function get urls() returns json[] {
        json[] urlList = [];
        foreach var [shortCode, mapping] in urlDatabase.entries() {
            urlList.push({
                "shortCode": mapping.shortCode,
                "longUrl": mapping.longUrl,
                "clicks": mapping.clickCount,
                "createdAt": mapping.createdAt
            });
        }
        return urlList;
    }

    // Resource for metrics endpoint (Prometheus will scrape this)
    // This is automatically exposed by the Prometheus exporter
}

//=============================================================================
// URL SHORTENING FUNCTIONS
//=============================================================================

// URL shortening function
function generateShortCode(string longUrl) returns string {
    // Create a hash of the URL
    byte[] urlHash = crypto:hashSha256(longUrl.toBytes());
    // Convert to base64 and take first 8 characters
    string encoded = array:toBase64(urlHash);
    return encoded.substring(0, 8);
}

//=============================================================================
// STORAGE FUNCTIONS
//=============================================================================

// Save a URL mapping
function saveUrl(string shortCode, string longUrl) returns UrlMapping {
    UrlMapping mapping = {
        shortCode: shortCode,
        longUrl: longUrl,
        clickCount: 0,
        createdAt: time:utcToString(time:utcNow())
    };
    
    urlDatabase[shortCode] = mapping;
    return mapping;
}

// Get a URL mapping by short code
function getUrl(string shortCode) returns UrlMapping? {
    if urlDatabase.hasKey(shortCode) {
        return urlDatabase[shortCode];
    }
    return ();
}

// Increment the click count for a URL
function incrementClickCount(string shortCode) {
    if urlDatabase.hasKey(shortCode) {
        UrlMapping? mappingOptional = urlDatabase[shortCode];
        if mappingOptional is UrlMapping {
            mappingOptional.clickCount += 1;
            urlDatabase[shortCode] = mappingOptional;
        }
    }
}

//=============================================================================
// METRICS FUNCTIONS
//=============================================================================

// Record URL creation
function recordUrlCreation() {
    urlCreationCounter.increment(1);
    activeUrlsGauge.increment(1);
}

// Record URL redirect
function recordUrlRedirect(string shortCode) {
    urlRedirectCounter.increment(1);
}

//=============================================================================
// MAIN FUNCTION
//=============================================================================

public function main() {
    io:println("URL Shortener Service started on port: " + port.toString());
}