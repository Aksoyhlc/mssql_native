// Direct bindings for FreeTDS DB-Library 1.5.16.
// Header references point to the vendored sybdb.h used by the native build.
// Value decoding and connection ownership live outside this binding layer.
import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Return codes, type codes and login field ids from `sybdb.h`.
abstract final class Syb {
  // Return codes — sybdb.h:580-586
  static const int regRow = -1;
  static const int moreRows = -1;
  static const int noMoreRows = -2;
  static const int noMoreResults = 2;
  static const int succeed = 1;
  static const int fail = 0;

  /// `dbsetlname` field ids — sybdb.h:1248-1256
  static const int setHost = 1;
  static const int setUser = 2;
  static const int setPwd = 3;

  /// `DBSETAPP` — sybdb.h:1261. The application name the server logs.
  static const int setApp = 5;

  /// `DBSETCHARSET` — sybdb.h:1276.
  ///
  /// Requested client charset; FreeTDS converts server text through iconv.
  static const int setCharset = 10;

  /// `DBSETPACKET` — sybdb.h:1278. Network packet size; 0 means the server's.
  static const int setPacket = 11;

  /// `DBSETENCRYPTION` — sybdb.h:1304. Certificate trust remains external.
  static const int setEncryption = 1005;

  /// `dbsetlbool` field id that enables bulk copy — sybdb.h:1264
  static const int setBcp = 6;

  /// `DBSETNETWORKAUTH` — sybdb.h:1289.
  static const int setNetworkAuth = 101;

  /// `bcp_options` option id for a hint string — sybdb.h:114
  static const int bcpHints = 6;

  /// Preserve caller-supplied identity values — sybdb.h:111.
  static const int bcpKeepIdentity = 8;

  /// The error handler's exceptional return. sybdb.h defines INT_EXIT as 0,
  /// which terminates the process, so a throwing Dart handler must never fall
  /// back to it.
  static const int intCancel = 2;

  // Data types — sybdb.h:158-203
  static const int charType = 47;
  static const int varchar = 39;
  static const int intn = 38;
  static const int int1 = 48;
  static const int int2 = 52;
  static const int int4 = 56;
  static const int int8 = 127;
  static const int flt8 = 62;
  static const int datetime = 61;
  static const int bit = 50;
  static const int text = 35;
  static const int image = 34;
  static const int money4 = 122;
  static const int money = 60;
  static const int datetime4 = 58;
  static const int real = 59;
  static const int binary = 45;
  static const int varbinary = 37;
  static const int numeric = 108;
  static const int decimal = 106;
  static const int fltn = 109;
  static const int moneyn = 110;
  static const int datetimn = 111;
  static const int bitn = 104;
  static const int nvarchar = 103;
  static const int nchar = 239;
  static const int ntext = 99;
  static const int msdate = 40;
  static const int mstime = 41;
  static const int msdatetime2 = 42;
  static const int msdatetimeoffset = 43;
  static const int bigdatetime = 187;
  static const int bigtime = 188;

  /// Legacy Sybase date/time. SQL Server does not send these, but
  /// logical_type_for_native in the bridge handled them and this mapping is a
  /// faithful port. — sybdb.h:212, 214
  /// `SYBUNIQUE` — freetds/proto.h:220. `uniqueidentifier`. Not in sybdb.h,
  /// but `dbcoltype` reports it, and it has to go through `dbconvert` to be
  /// read as the canonical hyphenated text rather than sixteen raw bytes.
  static const int unique = 36;

  /// `SYBMSXML` — freetds/proto.h:223.
  static const int msxml = 241;

  static const int date = 49;
  static const int time = 51;
}

/// `EHANDLEFUNC` — sybdb.h:531
typedef ErrHandlerNative =
    Int32 Function(
      Pointer<Void>,
      Int32,
      Int32,
      Int32,
      Pointer<Utf8>,
      Pointer<Utf8>,
    );

/// `MHANDLEFUNC` — sybdb.h:533
typedef MsgHandlerNative =
    Int32 Function(
      Pointer<Void>,
      Int32,
      Int32,
      Int32,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Int32,
    );

/// The DB-Library entry points this driver uses.
///
/// DB-Library entry points resolved independently in each worker isolate.
class DbLib {
  DbLib(DynamicLibrary lib)
    : dbinit = lib.lookupFunction<Int32 Function(), int Function()>('dbinit'),
      dbexit = lib.lookupFunction<Void Function(), void Function()>('dbexit'),
      dblogin = lib
          .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
            'dblogin',
          ),
      dbloginfree = lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('dbloginfree'),
      dbsetlname = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32),
            int Function(Pointer<Void>, Pointer<Utf8>, int)
          >('dbsetlname'),
      dbsetlbool = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Int32, Int32),
            int Function(Pointer<Void>, int, int)
          >('dbsetlbool'),
      dbsetllong = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Long, Int32),
            int Function(Pointer<Void>, int, int)
          >('dbsetllong'),
      dbsetlversion = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Uint8),
            int Function(Pointer<Void>, int)
          >('dbsetlversion'),
      dbsetlogintime = lib
          .lookupFunction<Int32 Function(Int32), int Function(int)>(
            'dbsetlogintime',
          ),
      dbsettime = lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
        'dbsettime',
      ),
      // `dbopen` is a macro over `tdsdbopen` — sybdb.h:850. msdblib = 1
      // matches the --enable-msdblib the vendored FreeTDS is built with.
      tdsdbopen = lib
          .lookupFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Int32),
            Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, int)
          >('tdsdbopen'),
      dbclose = lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('dbclose'),
      dbuse = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Utf8>),
            int Function(Pointer<Void>, Pointer<Utf8>)
          >('dbuse'),
      dbname = lib
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>),
            Pointer<Utf8> Function(Pointer<Void>)
          >('dbname'),
      dbtds = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('dbtds'),
      dbversion = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'dbversion',
          ),
      dbcmd = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Utf8>),
            int Function(Pointer<Void>, Pointer<Utf8>)
          >('dbcmd'),
      dbsqlexec = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('dbsqlexec'),
      dbsqlok = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('dbsqlok'),
      dbresults = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('dbresults'),
      dbmorecmds = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('dbmorecmds'),
      dbcancel = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('dbcancel'),
      dbanydatecrack = lib
          .lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Pointer<Int32>,
              Int32,
              Pointer<Uint8>,
            ),
            int Function(Pointer<Void>, Pointer<Int32>, int, Pointer<Uint8>)
          >('dbanydatecrack'),
      dbcanquery = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('dbcanquery'),
      // DBBOOL, an unsigned char — sybdb.h:761. Non-zero once the connection
      // is gone, whether or not FreeTDS also reported it through a handler.
      dbdead = lib
          .lookupFunction<
            Uint8 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('dbdead'),
      dbiscount = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('dbiscount'),
      dbnumcols = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('dbnumcols'),
      dbcolname = lib
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>, Int32),
            Pointer<Utf8> Function(Pointer<Void>, int)
          >('dbcolname'),
      dbcoltype = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Int32),
            int Function(Pointer<Void>, int)
          >('dbcoltype'),
      dbcollen = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Int32),
            int Function(Pointer<Void>, int)
          >('dbcollen'),
      dbnextrow = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('dbnextrow'),
      dbdata = lib
          .lookupFunction<
            Pointer<Uint8> Function(Pointer<Void>, Int32),
            Pointer<Uint8> Function(Pointer<Void>, int)
          >('dbdata'),
      dbdatlen = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Int32),
            int Function(Pointer<Void>, int)
          >('dbdatlen'),
      dbconvert = lib
          .lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Int32,
              Pointer<Uint8>,
              Int32,
              Int32,
              Pointer<Uint8>,
              Int32,
            ),
            int Function(
              Pointer<Void>,
              int,
              Pointer<Uint8>,
              int,
              int,
              Pointer<Uint8>,
              int,
            )
          >('dbconvert'),
      dbcount = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('dbcount'),
      dbhasretstat = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('dbhasretstat'),
      dbretstatus = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('dbretstatus'),
      dbnumrets = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('dbnumrets'),
      dbretname = lib
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>, Int32),
            Pointer<Utf8> Function(Pointer<Void>, int)
          >('dbretname'),
      dbrettype = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Int32),
            int Function(Pointer<Void>, int)
          >('dbrettype'),
      dbretlen = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Int32),
            int Function(Pointer<Void>, int)
          >('dbretlen'),
      dbretdata = lib
          .lookupFunction<
            Pointer<Uint8> Function(Pointer<Void>, Int32),
            Pointer<Uint8> Function(Pointer<Void>, int)
          >('dbretdata'),
      dbrpcinit = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Utf8>, Int16),
            int Function(Pointer<Void>, Pointer<Utf8>, int)
          >('dbrpcinit'),
      dbrpcparam = lib
          .lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Pointer<Utf8>,
              Uint8,
              Int32,
              Int32,
              Int32,
              Pointer<Uint8>,
            ),
            int Function(
              Pointer<Void>,
              Pointer<Utf8>,
              int,
              int,
              int,
              int,
              Pointer<Uint8>,
            )
          >('dbrpcparam'),
      dbrpcsend = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('dbrpcsend'),
      dberrhandle = lib
          .lookupFunction<
            Pointer<NativeFunction<ErrHandlerNative>> Function(
              Pointer<NativeFunction<ErrHandlerNative>>,
            ),
            Pointer<NativeFunction<ErrHandlerNative>> Function(
              Pointer<NativeFunction<ErrHandlerNative>>,
            )
          >('dberrhandle'),
      dbmsghandle = lib
          .lookupFunction<
            Pointer<NativeFunction<MsgHandlerNative>> Function(
              Pointer<NativeFunction<MsgHandlerNative>>,
            ),
            Pointer<NativeFunction<MsgHandlerNative>> Function(
              Pointer<NativeFunction<MsgHandlerNative>>,
            )
          >('dbmsghandle'),
      bcpInit = lib
          .lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Int32,
            ),
            int Function(
              Pointer<Void>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              int,
            )
          >('bcp_init'),
      bcpBind = lib
          .lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Pointer<Uint8>,
              Int32,
              Int32,
              Pointer<Uint8>,
              Int32,
              Int32,
              Int32,
            ),
            int Function(
              Pointer<Void>,
              Pointer<Uint8>,
              int,
              int,
              Pointer<Uint8>,
              int,
              int,
              int,
            )
          >('bcp_bind'),
      bcpCollen = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Int32, Int32),
            int Function(Pointer<Void>, int, int)
          >('bcp_collen'),
      bcpColptr = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32),
            int Function(Pointer<Void>, Pointer<Uint8>, int)
          >('bcp_colptr'),
      bcpSendrow = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('bcp_sendrow'),
      bcpBatch = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('bcp_batch'),
      bcpDone = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('bcp_done'),
      bcpControl = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Int32, Int32),
            int Function(Pointer<Void>, int, int)
          >('bcp_control'),
      bcpOptions = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Int32, Pointer<Uint8>, Int32),
            int Function(Pointer<Void>, int, Pointer<Uint8>, int)
          >('bcp_options');

  // Runtime — sybdb.h:782, 765
  final int Function() dbinit;
  final void Function() dbexit;

  // Login — sybdb.h:796, 797, 1242, 1243, 893, 898
  final Pointer<Void> Function() dblogin;
  final void Function(Pointer<Void>) dbloginfree;
  final int Function(Pointer<Void>, Pointer<Utf8>, int) dbsetlname;
  final int Function(Pointer<Void>, int, int) dbsetlbool;

  /// sybdb.h:1245.
  final int Function(Pointer<Void>, int, int) dbsetllong;

  /// sybdb.h:1246.
  final int Function(Pointer<Void>, int) dbsetlversion;
  final int Function(int) dbsetlogintime;
  final int Function(int) dbsettime;

  // Connection — sybdb.h:831, 727, 1235
  final Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, int) tdsdbopen;
  final void Function(Pointer<Void>) dbclose;
  final int Function(Pointer<Void>, Pointer<Utf8>) dbuse;
  final Pointer<Utf8> Function(Pointer<Void>) dbname;
  final int Function(Pointer<Void>) dbtds;
  final Pointer<Utf8> Function() dbversion;

  // Statements — sybdb.h:730, 908, 868, 819, 723, 724
  final int Function(Pointer<Void>, Pointer<Utf8>) dbcmd;
  final int Function(Pointer<Void>) dbsqlexec;
  final int Function(Pointer<Void>) dbsqlok;
  final int Function(Pointer<Void>) dbresults;
  final int Function(Pointer<Void>) dbmorecmds;
  final int Function(Pointer<Void>) dbcancel;

  /// sybdb.h:759. Fills a `DBDATEREC2` — twelve 32-bit fields, see
  /// [dateCrackFields] — from a packed date/time value.
  final int Function(Pointer<Void>, Pointer<Int32>, int, Pointer<Uint8>)
  dbanydatecrack;
  final int Function(Pointer<Void>) dbcanquery;
  final int Function(Pointer<Void>) dbdead;

  // Result metadata and rows — sybdb.h:828, 737, 756, 760, 736, 825, 743, 747
  final int Function(Pointer<Void>) dbnumcols;
  final Pointer<Utf8> Function(Pointer<Void>, int) dbcolname;
  final int Function(Pointer<Void>, int) dbcoltype;
  final int Function(Pointer<Void>, int) dbcollen;
  final int Function(Pointer<Void>) dbnextrow;
  final Pointer<Uint8> Function(Pointer<Void>, int) dbdata;
  final int Function(Pointer<Void>, int) dbdatlen;
  final int Function(
    Pointer<Void>,
    int,
    Pointer<Uint8>,
    int,
    int,
    Pointer<Uint8>,
    int,
  )
  dbconvert;
  final int Function(Pointer<Void>) dbcount;

  /// Whether `dbcount` is meaningful for the statement just run — sybdb.h:746.
  final int Function(Pointer<Void>) dbiscount;

  // Procedure return status and output parameters — sybdb.h:781, 873, 830, 872, 874, 871, 870
  final int Function(Pointer<Void>) dbhasretstat;
  final int Function(Pointer<Void>) dbretstatus;
  final int Function(Pointer<Void>) dbnumrets;
  final Pointer<Utf8> Function(Pointer<Void>, int) dbretname;
  final int Function(Pointer<Void>, int) dbrettype;
  final int Function(Pointer<Void>, int) dbretlen;
  final Pointer<Uint8> Function(Pointer<Void>, int) dbretdata;

  // RPC — sybdb.h:881, 882, 883
  final int Function(Pointer<Void>, Pointer<Utf8>, int) dbrpcinit;
  final int Function(
    Pointer<Void>,
    Pointer<Utf8>,
    int,
    int,
    int,
    int,
    Pointer<Uint8>,
  )
  dbrpcparam;
  final int Function(Pointer<Void>) dbrpcsend;

  // Handlers — sybdb.h:764, 823
  final Pointer<NativeFunction<ErrHandlerNative>> Function(
    Pointer<NativeFunction<ErrHandlerNative>>,
  )
  dberrhandle;
  final Pointer<NativeFunction<MsgHandlerNative>> Function(
    Pointer<NativeFunction<MsgHandlerNative>>,
  )
  dbmsghandle;

  // Bulk copy — sybdb.h:1309, 1313, 1315, 1321, 1328, 1312, 1310, 1322, 1326
  final int Function(
    Pointer<Void>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    int,
  )
  bcpInit;
  final int Function(
    Pointer<Void>,
    Pointer<Uint8>,
    int,
    int,
    Pointer<Uint8>,
    int,
    int,
    int,
  )
  bcpBind;
  final int Function(Pointer<Void>, int, int) bcpCollen;
  final int Function(Pointer<Void>, Pointer<Uint8>, int) bcpColptr;
  final int Function(Pointer<Void>) bcpSendrow;
  final int Function(Pointer<Void>) bcpBatch;
  final int Function(Pointer<Void>) bcpDone;
  final int Function(Pointer<Void>, int, int) bcpControl;
  final int Function(Pointer<Void>, int, Pointer<Uint8>, int) bcpOptions;

  /// `BCP_SETL(login, true)` — sybdb.h:1265. Must be set before `tdsdbopen`
  /// or bulk copy is unavailable on the connection.
  void enableBulkCopy(Pointer<Void> login) => dbsetlbool(login, 1, Syb.setBcp);

  /// Asks DB-Library to log in as the process's own Windows account.
  int enableNetworkAuthentication(Pointer<Void> login) =>
      dbsetlbool(login, 1, Syb.setNetworkAuth);

  /// `DBDATEREC2` is twelve `DBINT`s — sybdb.h:490. FreeTDS is built with
  /// `--enable-msdblib`, so the Microsoft layout is what `dbanydatecrack`
  /// fills: year is the real year and month is 1-12, where the Sybase layout
  /// would give 0-11.
  static const int dateCrackFields = 12;

  /// The `DBVERSION_*` byte for a TDS version string — sybdb.h:74-78.
  ///
  /// `MssqlConnectionConfig.validate` refuses anything outside
  /// `MssqlDefaults.tdsVersions`, so the fallback keeps this binding layer
  /// free of an error path it cannot report.
  static int tdsVersionByte(String version) => switch (version) {
    '7.0' => 4,
    '7.1' => 5,
    '7.2' => 6,
    '7.3' => 7,
    _ => 8,
  };
}
