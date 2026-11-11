import Foundation
import CryptoKit

enum DemoAnalysis {
    static func sql(for store: LocalStore) -> String {
        switch store {
        case .graph: DemoGraph.sql
        case .tagging: tagging
        case .interactions: interactions
        case .photos: photos
        case .features: """
            CREATE TABLE kv (viewName TEXT, featureName TEXT, subidentifierName TEXT, value BLOB);
            INSERT INTO kv VALUES
                ('personEntityTaggingFacts','sharedAddress','2',1),
                ('personEntityTaggingFacts','sharedAddress','4',0),
                ('personEntityTaggingFacts','emergencyContact','4',1),
                ('personEntityTaggingFacts','familySharing','7',1),
                ('personEntityTaggingFacts','familySharing','2',1),
                ('personEntityTagging','communicationVolume','2',1);
            """
        case .importance: """
            CREATE TABLE entityImportanceSignalsIDMap (entityIdentifier INTEGER, isICloudFamily INTEGER);
            INSERT INTO entityImportanceSignalsIDMap VALUES (2,1), (4,1), (7,0);
            """
        case .internalViews: """
            CREATE TABLE handle_id (handle TEXT, id INTEGER);
            INSERT INTO handle_id VALUES ('+12025550140',2), ('+12025550141',4), ('+12025550143',7);
            CREATE TABLE WifiContextEvents (subject INTEGER,predicate TEXT,relationshipId INTEGER,relationshipPredicate TEXT,object TEXT);
            CREATE TABLE featureExplanation (explanation TEXT, enabled INTEGER);
            INSERT INTO featureExplanation VALUES ('{"positiveContributions":[{"name":"activity:Wifi"}]}',0);
            """
        case .calendar: """
            CREATE TABLE CalendarItem (summary TEXT, start_date REAL, end_date REAL, description TEXT,
                conference_url_detected TEXT, conference_url TEXT);
            CREATE TABLE OccurrenceCache (occurrence_date REAL);
            CREATE TABLE Participant (owner_id INTEGER);
            CREATE TABLE Identity (address TEXT);
            CREATE TABLE Location (title TEXT, address TEXT, latitude REAL, longitude REAL);
            INSERT INTO CalendarItem VALUES ('Book Club Meeting',815702400,815706000,'Discussion',NULL,NULL),
                ('Catch-up Call',815802400,815806000,'Demo','https://meeting.example.test','https://meeting.example.test');
            INSERT INTO OccurrenceCache VALUES (815702400),(815802400);
            INSERT INTO Participant VALUES (1),(2),(2);
            INSERT INTO Identity VALUES ('lena@example.test'),('another@example.test');
            INSERT INTO Location VALUES ('Museum of Light','100 Example Avenue',52.52,13.41);
            """
        case .messages: """
            CREATE TABLE handle (id TEXT);
            INSERT INTO handle VALUES ('+12025550140'), ('+12025550141'), ('+12025550143');
            """
        case .views: """
            CREATE TABLE viewConfigRecord (id INTEGER, name TEXT, generationType TEXT, artifactType TEXT,
                artifactPath TEXT, artifactTable TEXT, writeToStream INTEGER, target TEXT, config TEXT);
            CREATE TABLE sourceListenerConfig (viewOrderedId INTEGER, sourceType TEXT, schedule TEXT, config TEXT);
            CREATE TABLE viewTables (viewOrderedId INTEGER, tableName TEXT);
            CREATE TABLE viewState (viewOrderedId INTEGER, tablesCreated INTEGER, bookmark BLOB, errorMessage TEXT);
            CREATE TABLE sourceState (sourceType TEXT, available INTEGER, updateType TEXT, sourceIdentifier TEXT, modifiedTimestamp REAL);
            CREATE TABLE sourceListenerState (sourceUpdatedTimestamp REAL);
            INSERT INTO viewConfigRecord VALUES
                (1,'personEntityTagging','projection','sqlite','Artifacts/entityTagging/entityTagging.db','entity_tagging',0,NULL,'{}'),
                (2,'communicationContext','incremental','sqlite','Artifacts/siri/remembers/view.db','interactions',0,NULL,'{"update":{"biomeListeners":[{"stream":"App.InstalledApp","schedule":"live","excludeLocal":true,"syncedDeviceTypes":["Mac","iPhone"]}]}}'),
                (3,'appCatalog','projection','sqlite','graph.db','stable_graph',1,'App.InstalledApp','{}');
            INSERT INTO sourceListenerConfig VALUES
                (1,'knowledgeGraph','daily','{"filters":[{"entityType":"SB104","predicates":["PS1"]}]}'),
                (2,'biome','live','{"filters":[]}'), (3,'knowledgeGraph','daily','{"filters":[{"predicates":["nm_bundleID"]}]}');
            INSERT INTO viewTables VALUES (1,'entity_tagging'), (2,'interactions'), (3,'stable_graph');
            INSERT INTO viewState VALUES (1,1,NULL,NULL), (2,1,NULL,NULL), (3,1,NULL,NULL);
            INSERT INTO sourceState VALUES ('knowledgeGraph',1,'snapshot','graph',815702400),
                ('biome',1,'live','App.InstalledApp',815702400),
                ('biome',1,'live','App.InstalledApp:remotes:demo-device',815702401);
            INSERT INTO sourceListenerState VALUES (815702400), (815702401), (815702402);
            """
        case .global: """
            CREATE TABLE catalog (name TEXT, count INTEGER, assetId INTEGER DEFAULT 1);
            CREATE TABLE response_cache (predicate TEXT, clients TEXT, ttlTimestamp REAL, timestamp REAL);
            CREATE INDEX response_cache_client ON response_cache(clients);
            CREATE TABLE static_assets (id INTEGER PRIMARY KEY, name TEXT, version TEXT, type TEXT);
            CREATE TABLE static_graph (subject INTEGER, assetId INTEGER);
            INSERT INTO static_assets VALUES (1,'demo-catalogue','1','demo');
            INSERT INTO static_graph VALUES (1,1),(2,1),(2,1);
            INSERT INTO response_cache VALUES ('PS1','demo',815702500,815702400);
            INSERT INTO catalog(name,count) VALUES ('person', 8), ('software', 3);
            """
        case .keyValue: """
            CREATE TABLE keyvalue (key TEXT, value BLOB);
            INSERT INTO keyvalue VALUES ('indexVersion','1'),('graphSnapshot','demo');
            """
        }
    }

    private static let tagging = """
        CREATE TABLE entity_tagging (
          mdid INTEGER PRIMARY KEY, mother DOUBLE, father DOUBLE, parent DOUBLE,
          sister DOUBLE, brother DOUBLE, sibling DOUBLE, child DOUBLE, partner DOUBLE,
          colleague DOUBLE, family DOUBLE, friends DOUBLE, familyAndFriends DOUBLE, unknown DOUBLE
        );
        INSERT INTO entity_tagging VALUES
          (2,0.96,0,0.96,0,0,0,0,0,0,0.96,0,0.96,0),
          (3,0,0,0,0,0,0,0,0,0.85,0.125,0.5,0.625,0),
          (4,0,0,0,0,0,0,0,0.96,0.5,0.96,0,0.96,0),
          (7,0,0,0,0.5,0,0.5,0,0,0,0.5,0.25,0.75,0),
          (10,0,0,0,0,0.5,0.5,0,0,0,0.5,0,0.5,0),
          (12,0,0,0,0,0,0,0,0,0,0.125,0.25,0.375,0),
          (16,0,0,0,0,0,0,0,0,0,0.2,0.3,0.45,0);
        """

    private static let interactions = """
        CREATE TABLE interactions (
            startDate REAL, durationSeconds REAL, direction INTEGER, domain TEXT, bundleId TEXT,
            remoteDeviceId TEXT, contentHash TEXT, type TEXT, handlingStatus INTEGER, isDonatedBySiri INTEGER,
            sourceStreams TEXT, fields TEXT
        );
        CREATE TABLE entities (type TEXT, fields TEXT, id TEXT);
        CREATE TABLE interactionEntities (interactionRowid INTEGER, entityRowid INTEGER, parameter TEXT);
        CREATE INDEX links_by_interaction ON interactionEntities(interactionRowid,parameter);
        INSERT INTO entities (type,fields) VALUES ('Person','{"name":"Mira Foster"}'),
            ('Person','{"name":"Anna Lee"}'), ('Person','{"name":"Lena Ray"}'),
            ('Person','{"name":"Leo Bennett"}'), ('Person','{"name":"Tim Lee"}'),
            ('Person','{"name":"Yana Brooks"}'), ('Message','{}'),
            ('MessageGroup','{"name":"Book Club"}'), ('MessageGroup','{"name":"Studio"}');
        INSERT INTO entities (type,fields,id) VALUES
            ('PersonHandle','{}','+12025550140'),('PersonHandle','{}','+12025550141'),('PersonHandle','{}','+12025550143');
        WITH RECURSIVE sequence(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM sequence WHERE i < 850)
        INSERT INTO interactions
        SELECT 784598400 + (i%365)*86400 + (7 + (i*13+i/11)%17)*3600,
          CASE WHEN i%11=0 AND i%7<>0 THEN 22 + (i*67)%1200 ELSE 0 END,
          CASE WHEN i%5<2 THEN 3 ELSE 7 END,
          CASE WHEN i%11=0 THEN 'Calls' ELSE 'Messages' END,
          CASE WHEN i%11=0 THEN 'com.apple.FaceTime'
               WHEN i%9<3 THEN 'org.example.messenger' ELSE 'com.apple.MobileSMS' END,
          CASE WHEN i%5=0 THEN 'demo-phone' ELSE '' END,
          printf('demo-%02d', i%17),
          CASE WHEN i%11=0 THEN 'INStartCallIntent' ELSE 'INSendMessageIntent' END,
          CASE WHEN i%7<>0 THEN 1 ELSE 2 END,
          i%8=0, CASE WHEN i%5=0 THEN 'phone' ELSE 'mac' END, '{}'
        FROM sequence;
        INSERT INTO interactionEntities
        SELECT rowid, CASE WHEN rowid%10<4 THEN 1 ELSE 2 + rowid%5 END,
          CASE direction WHEN 3 THEN 'sender' ELSE 'recipients' END FROM interactions;
        INSERT INTO interactionEntities
        SELECT rowid, 6, 'recipients' FROM interactions WHERE rowid%23=0 AND direction=7;
        INSERT INTO interactionEntities SELECT rowid, 8+(rowid%2),'group' FROM interactions WHERE rowid%7=0;
        INSERT INTO interactionEntities SELECT rowid, 10+(rowid%3),'handles' FROM interactions WHERE rowid%5<4;
        INSERT INTO interactionEntities SELECT rowid, 11,'handles' FROM interactions WHERE rowid%11=0;
        """

    private static let photos = """
        CREATE TABLE ZPERSON (
            Z_PK INTEGER PRIMARY KEY, ZPERSONUUID TEXT, ZFULLNAME TEXT, ZDISPLAYNAME TEXT,
            ZVERIFIEDTYPE INTEGER, ZDETECTIONTYPE INTEGER, ZTYPE INTEGER, ZKEYFACE INTEGER,
            ZFACECOUNT INTEGER, ZISME INTEGER
        );
        CREATE TABLE ZDETECTEDFACE (
            Z_PK INTEGER PRIMARY KEY, ZPERSONFORFACE INTEGER, ZASSETFORFACE INTEGER,
            ZCENTERX REAL, ZCENTERY REAL, ZSIZE REAL, ZQUALITY REAL, ZFACEPRINT INTEGER,
            ZSMILINGTYPE INTEGER, ZEYECLOSED INTEGER
        );
        CREATE TABLE ZASSET (
            Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZDATECREATED REAL, ZKIND INTEGER,
            ZORIENTATION INTEGER, ZWIDTH INTEGER, ZHEIGHT INTEGER, ZTRASHEDSTATE INTEGER,
            ZHIDDEN INTEGER, ZLATITUDE REAL, ZLONGITUDE REAL
        );
        CREATE TABLE ZFACEPRINT (ZDATA BLOB);
        CREATE TABLE ZSCENECLASSIFICATION (ZSCENEIDENTIFIER INTEGER, ZCLASSIFICATIONTYPE INTEGER, ZCONFIDENCE REAL, ZASSETATTRIBUTES INTEGER);
        CREATE TABLE ZMEDIAANALYSISASSETATTRIBUTES (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER);
        CREATE TABLE ZMEMORY (ZCATEGORY INTEGER, ZSUBCATEGORY INTEGER, ZTITLE TEXT,
            ZVIEWCOUNT INTEGER, ZPLAYCOUNT INTEGER, ZREJECTED INTEGER, ZSHARECOUNT INTEGER,
            ZCREATIONDATE REAL, ZLASTVIEWEDDATE REAL);
        CREATE TABLE Z_3MEMORIESBEINGCURATEDASSETS (Z_3MEMORIES INTEGER, Z_1CURATEDASSETS INTEGER);
        INSERT INTO Z_3MEMORIESBEINGCURATEDASSETS VALUES (1,1),(1,2),(2,2);
        CREATE TABLE ZADDITIONALASSETATTRIBUTES (ZASSET INTEGER, ZTIMEZONENAME TEXT);
        CREATE INDEX faces_by_photo ON ZDETECTEDFACE(ZASSETFORFACE, ZPERSONFORFACE);
        CREATE INDEX faces_by_person ON ZDETECTEDFACE(ZPERSONFORFACE, ZASSETFORFACE);
        INSERT INTO ZPERSON VALUES
          (1,'11111111-0000-0000-0000-000000000001','Sasha Morgan','Sasha',1,1,0,1,45,1),
          (2,'11111111-0000-0000-0000-000000000002','Mira Foster','Mira',1,1,0,2,31,0),
          (3,'11111111-0000-0000-0000-000000000003','Anna Lee','Anna',1,1,0,3,29,0),
          (4,'11111111-0000-0000-0000-000000000004','Leo Bennett','Leo',1,1,0,4,16,0),
          (5,'11111111-0000-0000-0000-000000000005',NULL,NULL,0,1,0,5,12,0),
          (6,'11111111-0000-0000-0000-000000000006','Lena Ray','Lena',1,1,0,6,12,0),
          (7,'11111111-0000-0000-0000-000000000007',NULL,NULL,0,1,0,7,8,0),
          (8,'11111111-0000-0000-0000-000000000008',NULL,NULL,0,1,0,8,9,0);
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<145)
        INSERT INTO ZASSET SELECT i, printf('22222222-0000-0000-0000-%012d',i),784598400+i*196200,
          i%9=0,1,1600,1200,i%41=0,i%53=0,
          CASE WHEN i%4=0 THEN -180 ELSE 52.0 END, CASE WHEN i%4=0 THEN -180 ELSE 12.0 END FROM n;
        INSERT INTO ZDETECTEDFACE (ZPERSONFORFACE,ZASSETFORFACE,ZCENTERX,ZCENTERY,ZSIZE,ZQUALITY,ZSMILINGTYPE,ZEYECLOSED)
          SELECT 1+(Z_PK*7+Z_PK/11)%8,Z_PK,0.32,0.62,0.20,0.71,Z_PK%4=0,Z_PK%9=0 FROM ZASSET;
        INSERT INTO ZDETECTEDFACE (ZPERSONFORFACE,ZASSETFORFACE,ZCENTERX,ZCENTERY,ZSIZE,ZQUALITY,ZSMILINGTYPE,ZEYECLOSED)
          SELECT 1+(Z_PK*7+Z_PK/11+1+Z_PK%4)%8,Z_PK,0.62,0.62,0.20,0.86,Z_PK%3=0,0 FROM ZASSET WHERE Z_PK%3<>0;
        INSERT INTO ZFACEPRINT SELECT zeroblob(128) FROM ZDETECTEDFACE WHERE Z_PK%4<>0;
        INSERT INTO ZMEDIAANALYSISASSETATTRIBUTES SELECT Z_PK+10000,Z_PK FROM ZASSET;
        INSERT INTO ZSCENECLASSIFICATION SELECT Z_PK%7,1,(45+Z_PK%54)/100.0,Z_PK+10000 FROM ZASSET;
        INSERT INTO ZMEMORY VALUES (1,7,'Summer',2,1,0,1,815600000,815700000),
            (1,7,'Evening',0,0,1,0,815650000,NULL),(2,1,NULL,0,0,0,0,815700000,NULL),
            (3,2,'Weekend',3,2,0,0,815700001,815702400);
        INSERT INTO ZADDITIONALASSETATTRIBUTES SELECT Z_PK,'Europe/Berlin' FROM ZASSET WHERE Z_PK%3=0;
        """

    static func appToken(_ bundleID: String) -> String {
        "lsBundleRecord:" + Data(SHA256.hash(data: Data(bundleID.utf8))).base64EncodedString()
    }
}
