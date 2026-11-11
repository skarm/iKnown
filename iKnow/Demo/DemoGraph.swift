import Foundation

enum DemoGraph {
    static let sql: String = {
        let schema = """
            subject INTEGER NOT NULL, predicate TEXT NOT NULL, relationshipId INTEGER DEFAULT 0,
            relationshipPredicate TEXT DEFAULT '', object TEXT, confidence REAL, sources INTEGER,
            sourceDuplicates TEXT, timestamp REAL
            """
        let tables = GraphLayer.allCases.map { layer in
            """
            CREATE TABLE \(layer.rawValue) (\(schema));
            CREATE INDEX \(layer.rawValue)_subject ON \(layer.rawValue)(subject, predicate);
            CREATE INDEX \(layer.rawValue)_object ON \(layer.rawValue)(object);
            """
        }.joined(separator: "\n")
        return tables + """

            CREATE TABLE graph_state (key TEXT PRIMARY KEY, value REAL);
            INSERT INTO graph_state VALUES ('buildFromScratchTimestamp',815616000),
                ('expiredTriplesPruneTimestamp',816307200);

            INSERT INTO stable_graph (subject,predicate,object,confidence,sources) VALUES
              (9007199254740993,'PS33','Sasha Morgan',1,1),
              (9007199254740993,'PS1','SB104',1,1),
              (9007199254740993,'nm_isCurrentUser','true',1,1),
              (2,'PS33','Mira Foster',1,1), (2,'PS1','SB104',1,1),
              (3,'PS33','Leo Bennett',1,1), (3,'PS1','SB104',1,1),
              (4,'PS33','Anna Lee',1,1), (4,'PS1','SB104',1,1),
              (5,'PS33','Northpoint Studio',1,1), (5,'PS1','SB10',1,1),
              (6,'PS33','Book Club',0.8,2), (6,'PS1','SB2',0.8,2),
              (7,'PS33','Lena Ray',1,1), (7,'PS1','SB104',1,1),
              (8,'PS33','Museum of Light',1,1), (8,'PS1','SB152',1,1),
              (9,'PS33','Family',0.96,8192), (9,'PS1','SB2',0.96,8192),
              (10,'PS33','Tim Lee',1,1), (10,'PS1','SB104',1,1),
              (11,'PS33','Notes',1,32768), (11,'PS1','SB144',1,32768),
              (12,'PS312','Yana',1,1), (12,'PS441','Brooks',1,1), (12,'PS1','SB104',1,1);

            INSERT INTO stable_graph VALUES
              (9007199254740993,'PS500',500,'PS1','CS126',0.8,1025,'cnContact:demo-sasha',815616000),
              (9007199254740993,'PS500',500,'PS45','md:5',0.8,1025,'cnContact:demo-sasha',815616000),
              (9007199254740993,'PS520',520,'PS1','CS97',1,1,'cnContact:demo-sasha',815616000),
              (9007199254740993,'PS520',520,'PS407','+1 202 555 0142',1,1,'cnContact:demo-sasha',815616000),
              (9007199254740993,'PS520',520,'PS740','personal',1,1,'cnContact:demo-sasha',815616000),
              (9007199254740993,'demo_friend',0,'','md:2',1,1,'cnContact:demo-mira',815702400),
              (9007199254740993,'demo_friend',0,'','md:4',0.9,32,'phPerson:demo-anya',815702400),
              (2,'demo_friend',0,'','md:9007199254740993',0.9,32,'phPerson:demo-mira',815702400),
              (2,'demo_friend',0,'','md:12',0.9,32,'phPerson:demo-yana',815702400),
              (3,'demo_friend',0,'','md:9007199254740993',0.9,32,'phPerson:demo-lev',815702400),
              (6,'PS753',600,'PS566','md:9007199254740993',0.8,2,'inPerson:demo-club',815702400),
              (6,'PS753',600,'PS566','md:7',0.8,2,'inPerson:demo-club',815702400),
              (6,'PS753',600,'PS566','md:12',0.8,2,'inPerson:demo-club',815702400),
              (6,'demo_place',0,'','md:8',0.8,256,'ekEvent:demo-book-club',815702400),
              (9,'PS753',900,'PS566','md:9007199254740993',0.96,8192,'faFamilyCircle:demo',815702400),
              (9,'PS753',900,'PS566','md:10',0.96,8192,'faFamilyCircle:demo',815702400);

            INSERT INTO stable_graph (subject,predicate,object,confidence,sources) VALUES
              (9007199254740993,'nm_hasVisualIdentifier','phPerson:11111111-0000-0000-0000-000000000001/L0/001',0.9,32),
              (2,'nm_hasVisualIdentifier','phPerson:11111111-0000-0000-0000-000000000002/L0/001',0.9,32),
              (3,'nm_hasVisualIdentifier','phPerson:11111111-0000-0000-0000-000000000004/L0/001',0.9,32),
              (4,'nm_hasVisualIdentifier','phPerson:11111111-0000-0000-0000-000000000003/L0/001',0.9,32),
              (7,'nm_hasVisualIdentifier','phPerson:11111111-0000-0000-0000-000000000006/L0/001',0.9,32),
              (2,'PS317','cnContact:demo-mira:ABPerson',1,1),
              (4,'PS317','cnContact:demo-anya:ABPerson',1,1),
              (9,'PS317','faFamilyCircle:demo',0.96,8192),
              (30,'PS33','Berlin Brandenburg Airport',1,2048),
              (30,'nm_iataCode','BER',1,2048),
              (31,'PS33','Charles de Gaulle Airport',1,2048),
              (31,'nm_iataCode','CDG',1,2048),
              (11,'nm_bundleID','com.apple.Notes',1,32768),
              (11,'PS317','\(DemoAnalysis.appToken("com.apple.Notes"))',1,32768),
              (13,'PS1','SB144',1,32768),
              (13,'PS33','Photos',1,32768),
              (13,'nm_bundleID','com.apple.Photos',1,32768),
              (13,'PS317','\(DemoAnalysis.appToken("com.apple.Photos"))',1,32768),
              (14,'PS1','SB144',1,32768),
              (14,'PS33','Example Messenger',1,32768),
              (14,'nm_bundleID','org.example.messenger',1,32768),
              (14,'PS317','\(DemoAnalysis.appToken("org.example.messenger"))',1,32768);
            INSERT INTO stable_graph VALUES
              (2,'PS520',21,'PS407','+12025550140',1,1,'cnContact:demo-mira',815702400),
              (4,'PS520',41,'PS407','+12025550141',1,1,'cnContact:demo-anya',815702400),
              (7,'PS520',71,'PS407','+12025550143',1,1,'cnContact:demo-lena',815702400),
              (7,'PS520',72,'PS406','lena@example.test',1,1,'cnContact:demo-lena',815702400),
              (3,'PS500',301,'PS45','md:5',0.8,1,'cnContact:demo-lev',815702400),
              (12,'PS500',1201,'PS45','md:5',0.8,1,'cnContact:demo-yana',815702400);

            INSERT INTO event_graph VALUES
              (105,'PS1',0,'','SB514',1,2048,NULL,815702400),
              (105,'PS33',0,'','Flight to Paris',1,2048,NULL,815702400),
              (105,'PS51',0,'','Reservation',1,2048,NULL,815702400),
              (105,'nm_sgEventType',0,'','Flight',1,2048,NULL,815702400),
              (105,'nm_iataCode',0,'','EX',1,2048,NULL,815702400),
              (105,'nm_flightNumber',0,'','EX124',1,2048,NULL,815702400),
              (105,'PS248',0,'','md:30',1,2048,NULL,815702400),
              (105,'PS249',0,'','md:31',1,2048,NULL,815702400),
              (105,'nm_hasDate',1051,'PS29','{"year":2027,"month":3,"day":1,"hour":10}',1,2048,NULL,815702400),
              (101,'PS1',0,'','SB472',1,256,NULL,815702400),
              (101,'PS33',0,'','Book Club Meeting',1,256,NULL,815702400),
              (101,'PS51',0,'','Book Discussion',1,256,NULL,815702400),
              (101,'PS580',0,'','md:9007199254740993',1,256,NULL,815702400),
              (101,'PS102',0,'','ekEvent:demo-book-club',1,256,NULL,815702400),
              (101,'PS232',1012,'PS143','md:9007199254740993',1,256,'ekEvent:demo-book-club',815702400),
              (101,'PS232',1013,'PS143','md:7',1,256,'ekEvent:demo-book-club',815702400),
              (101,'nm_hasDate',1011,'PS29','{"year":2027,"month":1,"day":12,"hour":18,"minute":30,"timeZone":{"identifier":"Europe/Berlin"}}',1,256,NULL,815702400),
              (101,'PS225',1014,'PS733','Museum of Light',1,256,NULL,815702400),
              (101,'demo_place',0,'','md:8',1,256,'ekEvent:demo-book-club',815702400),
              (102,'PS1',0,'','SB472',1,256,NULL,815702400),
              (102,'PS33',0,'','Museum Tour',1,256,NULL,815702400),
              (102,'nm_hasDate',1021,'PS29','{"year":2026,"month":10,"day":19}',1,256,NULL,815702400),
              (102,'demo_place',0,'','md:8',1,256,'ekEvent:demo-museum',815702400),
              (104,'PS33',0,'','Book Club Meeting',1,256,NULL,815702400),
              (104,'nm_hasDate',1041,'PS29','{"year":2027,"month":2,"day":12}',1,256,NULL,815702400),
              (104,'PS232',1042,'PS143','md:7',1,256,NULL,815702400),
              (104,'PS232',1043,'PS143','md:12',1,256,NULL,815702400);

            INSERT INTO expired_stable_graph VALUES
              (7,'PS33',0,'','Lena Ray',1,1,NULL,815616000),
              (7,'PS1',0,'','SB104',1,1,NULL,815616000),
              (7,'demo_friend',0,'','md:9007199254740993',0.7,2,'inPerson:demo-lena',815616000),
              (16,'PS33',0,'','Archived Contact',0.8,1,NULL,815616000),
              (16,'PS1',0,'','SB104',0.8,1,NULL,815616000),
              (16,'PS520',1601,'PS407','+12025550146',0.8,1,NULL,815616000),
              (16,'PS102',0,'','cnContact:demo-archive',0.8,1,NULL,815616000),
              (16,'PS102',0,'','ekEvent:demo-book-club',0.8,1,NULL,815616000);

            INSERT INTO expired_event_graph VALUES
              (103,'PS1',0,'','SB472',1,256,NULL,815616000),
              (103,'PS33',0,'','Workshop Meeting',1,256,NULL,815616000),
              (103,'PS232',1032,'PS143','md:3',1,256,'ekEvent:demo-workshop',815616000),
              (101,'PS232',1102,'PS143','md:7',1,256,NULL,815616000);
            """
    }()
}
