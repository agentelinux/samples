import ballerina/http;
import ballerina/log;
import ballerina/io;
import ballerina/system;
import ballerina/math;
import ballerina/runtime;
import ballerina/h2;

type ApplicationInfo record {
    string name;
    string ssn;
    int loan_amount;
    string zipcode;
    int income;
    boolean married;
};

type ApplicationEntry record {
    string state = "RISK_ASSESMENT";
    string comment = "";
    string appid;
    ApplicationInfo appinfo;
};

type ApplicationReview record {
    string appid;
    string result;
    string comment;
};

type DBEntry record {
    string appid;
    string data;
};

channel<json> reviewChannel = new ;


h2:Client appdb = new({
    path: "./app-data",
    name: "app-data",
    username: "admin",
    password: "admin"
});


http:AuthProvider basicAuthProvider = {
   scheme:"BASIC_AUTH",
   authStoreProvider:"CONFIG_AUTH_STORE"
};

http:ServiceEndpointConfiguration secureLoanServiceEp = {
   secureSocket: {
       keyStore: {
           path: "${ballerina.home}/bre/security/ballerinaKeystore.p12",
           password: "ballerina"
       }
   }
};

listener http:Listener secureLoanService = new(9090, config = secureLoanServiceEp);



@http:ServiceConfig {
   basePath:"/LoanService"
}

service LoanService on secureLoanService {

    @http:ResourceConfig {
        body: "appinfo",
        methods: ["POST"],
        path: "/application"
    }

    resource function application(http:Caller caller, http:Request req, ApplicationInfo appinfo) {

        string appid = generateApplicationID();

        json jsonMsg;
        //jsonMsg = <- reviewChannel, appid;
        jsonMsg = {"ApplicationID" : appid} ;

        //{"ApplicationID" : appid}


        error? result = caller -> respond(jsonMsg);
        if (result is error) {
            io:println("Error in responding", result);
        }    

        processApplication(appid, appinfo);
        
    }

    @http:ResourceConfig {
        methods: ["GET"],
        path: "/application/{applicationID}"
    }

    resource function get_application(http:Caller caller, http:Request req, string applicationID) {

        json jsonMsg;
        jsonMsg = getApplicationEntry(applicationID);

        error? result = caller -> respond(jsonMsg);
        if (result is error) {
            io:println("Error in responding", result);
        }            
    }

    @http:ResourceConfig {
        methods: ["GET"],
        path: "/application/all"
    }

    resource function get_all_applications(http:Caller caller, http:Request req, string applicationID) {

        json jsonMsg;
        jsonMsg = getAllApplicationEntries();

        error? result = caller -> respond(jsonMsg);
        if (result is error) {
            io:println("Error in responding", result);
        }            
    }
    
    @http:ResourceConfig {
        methods: ["POST"],
        path: "/application_review/",
        body: "applicationReview",
        authConfig:{
            scopes:["underwriter"]
        }
    }


    resource function add_application_review(http:Caller caller, http:Request req, ApplicationReview applicationReview) {

        json jsonMsg;
        json Msg;
        Msg = check <json> applicationReview;

        jsonMsg = {"Stats" : "Submit Review", "ApplicationID" : untaint applicationReview.appid,
                            "Message" : untaint Msg};
    
        error? result = caller -> respond(jsonMsg);
        if (result is error) {
            io:println("Error in responding", result);
        }

        Msg ->  reviewChannel, applicationReview.appid;             
    }

    @http:ResourceConfig {
        methods: ["GET"],
        path: "/init_db"
    }

    resource function initDB(http:Caller caller, http:Request req) {


        error? resultdb = check appdb->update("CREATE TABLE APPLICATION_ENTRY (appid VARCHAR(100), data CLOB, PRIMARY KEY (appid))");
        if (result is error) {
            io:println("Error in resultdb", result);
        } 
        error? result = caller -> respond(resultdb);
        if (result is error) {
            io:println("Error in result", result);
        }            
    }

}

function storeApplicationEntry(ApplicationEntry entry) {
    json content = check <json> entry;
    _ = appdb->update("MERGE INTO APPLICATION_ENTRY KEY(appid) VALUES (?,?)", entry.appid, 
                     content.toString());
}

function getApplicationEntry(string appid) returns json {
    table<DBEntry> data = check appdb->select("SELECT * from APPLICATION_ENTRY WHERE appid=?", DBEntry, appid);
    return generateDBResultJSON(data);
}

function getAllApplicationEntries() returns json {
    table<DBEntry> data = check appdb->select("SELECT * from APPLICATION_ENTRY", DBEntry);
    return generateDBResultJSON(data);
}

function generateDBResultJSON(table<DBEntry> data) returns json {
    json result = [];
    int i = 0;
    
    foreach var entry in data {
        io:println(entry);
        io:StringReader reader = new io:StringReader(entry.data);
        result[i] = check reader.readJson();
    }
    return result;
}

function generateApplicationID() returns string {
    return system:uuid();
}

function lookupCreditScore(string ssn) returns int {
    return <int> (math:random() * 850.0);
}

function approveApplication(ApplicationEntry entry, string reason) {
    entry.state = "APPROVED";
    entry.comment = reason;
    storeApplicationEntry(entry);
    io:println("Loan Application Approved: ", entry.appid, ", Comment: ", entry.comment);
}

function denyApplication(ApplicationEntry entry, string reason) {
    entry.state = "DENIED";
    entry.comment = reason;
    storeApplicationEntry(entry);
    io:println("Loan Application Denied: ", entry.appid, ", Comment: ", entry.comment);
}

function processReviewApplication(ApplicationEntry entry) {
    entry.state = "IN-REVIEW";
    storeApplicationEntry(entry);
    json message;
    // Wait for review decision. These channel receives are used to wait for external 
    // triggers to be sent to the process to continue the execution
    runtime:checkpoint();
    message -> reviewChannel, entry.appid;
    string result = check <string> message.result;
    string comment = check <string> message.comment;
    io:println("Review Received: " + result, ", Message: ", comment);
    if (result == "APPROVED") {
        approveApplication(entry, comment);
    } else {
        denyApplication(entry, comment);
    }
}

function processApplication(string appid, ApplicationInfo appinfo) {
    // Create and store the application 
    ApplicationEntry entry = {};
    entry.appid = appid;
    entry.appinfo = appinfo;
    storeApplicationEntry(entry);
    io:println("New Application: ", check <json> appinfo, " ApplicationID: ", appid);

    // Check credit score for risk analysis
    int credit_score = lookupCreditScore(appinfo.ssn);
    io:println("Credit Score: ", credit_score);
   
    if (credit_score >= 690) {
        // Good credit score, we will immediately approve this
        io:println("Good Credit Score, Loan Approved Immediately.");
        approveApplication(entry, "Good Credit Score");
    } else {
        // Not-so-good, a human will review the application
        io:println("Credit Score Questionable, Loan In Review State.");
        processReviewApplication(entry);
    }
}
