// import 'package:flutter/gestures.dart';
// import 'package:flutter/material.dart';
// import 'package:flutter_bmflocation/flutter_bmflocation.dart';
//
// void main() {
//   runApp(const MyApp());
// }
//
// class MyApp extends StatelessWidget {
//   const MyApp({super.key});
//
//   // This widget is the root of your application.
//   @override
//   Widget build(BuildContext context) {
//     return MaterialApp(
//       title: 'Flutter Demo',
//       theme: ThemeData(
//         // This is the theme of your application.
//         //
//         // TRY THIS: Try running your application with "flutter run". You'll see
//         // the application has a purple toolbar. Then, without quitting the app,
//         // try changing the seedColor in the colorScheme below to Colors.green
//         // and then invoke "hot reload" (save your changes or press the "hot
//         // reload" button in a Flutter-supported IDE, or press "r" if you used
//         // the command line to start the app).
//         //
//         // Notice that the counter didn't reset back to zero; the application
//         // state is not lost during the reload. To reset the state, use hot
//         // restart instead.
//         //
//         // This works for code too, not just values: Most code changes can be
//         // tested with just a hot reload.
//         colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
//         useMaterial3: true,
//       ),
//       home: const MyHomePage(title: 'Flutter Demo Home Page'),
//     );
//   }
// }
//
// class MyHomePage extends StatefulWidget {
//   const MyHomePage({super.key, required this.title});
//
//   // This widget is the home page of your application. It is stateful, meaning
//   // that it has a State object (defined below) that contains fields that affect
//   // how it looks.
//
//   // This class is the configuration for the state. It holds the values (in this
//   // case the title) provided by the parent (in this case the App widget) and
//   // used by the build method of the State. Fields in a Widget subclass are
//   // always marked "final".
//
//   final String title;
//
//   @override
//   State<MyHomePage> createState() => _MyHomePageState();
// }
//
// class _MyHomePageState extends State<MyHomePage> {
//   int _counter = 0;
//
//   final LocationFlutterPlugin _myLocPlugin = LocationFlutterPlugin()
//     ..setAgreePrivacy(true);
//
//   BaiduLocationAndroidOption initAndroidOptions() {
//     BaiduLocationAndroidOption options =
//     BaiduLocationAndroidOption(
// // 定位模式，可选的模式有高精度、仅设备、仅网络。认为高精度模式
//     locationMode: BMFLocationMode.hightAccuracy,
// // 是否需要返回地址信息
//     isNeedAddress: true,
// // 是否需要返回海拔高度信息
//     isNeedAltitude: true,
// // 是否需要返回周边poi信息
//     isNeedLocationPoiList: true,
// // 是否需要返回新版本rgc信息
//     isNeedNewVersionRgc: true,
// // 是否需要返回位置描述信息
//     isNeedLocationDescribe: true,
// // 是否使用gps
//     openGps: true,
// // 可选，设置场景定位参数，包括签到场景、运动场景、出行场景
//     locationPurpose: BMFLocationPurpose.sport,
// // 坐标系
//     coordType: BMFLocationCoordType.bd09ll,
// // 设置发起定位请求的间隔，int类型，单位ms
// // 如果设置为0，则代表单次定位，即仅定位一次，默认为0
//     scanspan: 0);
//     return options;
//   }
//
//
//   BaiduLocationIOSOption initIOSOptions() {
//     BaiduLocationIOSOption options =
//     BaiduLocationIOSOption(
//       // 坐标系
//         coordType: BMFLocationCoordType.bd09ll,
//         // 位置获取超时时间
//         locationTimeout: 10,
//         // 获取地址信息超时时间
//         reGeocodeTimeout: 10,
//         // 应用位置类型 默认为automotiveNavigation
//         activityType:
//         BMFActivityType.automotiveNavigation,
//         // 设置预期精度参数 默认为best
//         desiredAccuracy: BMFDesiredAccuracy.best,
//         // 是否需要最新版本rgc数据
//         isNeedNewVersionRgc: true,
//         // 指定定位是否会被系统自动暂停
//         pausesLocationUpdatesAutomatically: false,
//         // 指定是否允许后台定位,
//         // 允许的话是可以进行后台定位的，但需要项配置允许后台定位，否则会报错，具体参考开发文档
//     allowsBackgroundLocationUpdates: true,
//     // 设定定位的最小更新距离
//     distanceFilter: 10,
//     );
//     return options;
//   }
//
//   List<BaiduLocation> locationList = [];
//
//   @override
//   void initState() {
//     // TODO: implement initState
//     super.initState();
//     _myLocPlugin.seriesLocationCallback(callback: (BaiduLocation result){
//       _myLocPlugin.stopLocation();
//       setState(() {
//         locationList.add(result);
//       });
//     });
//   }
//
//   void _incrementCounter() async {
//     Map androidMap = initAndroidOptions().getMap();
//     Map iosMap = initIOSOptions().getMap();
//
//     await _myLocPlugin.prepareLoc(androidMap, iosMap);
//     await _myLocPlugin.startLocation();
//   }
//
//   @override
//   Widget build(BuildContext context) {
//
//     return Scaffold(
//       appBar: AppBar(
//         // TRY THIS: Try changing the color here to a specific color (to
//         // Colors.amber, perhaps?) and trigger a hot reload to see the AppBar
//         // change color while the other colors stay the same.
//         backgroundColor: Theme.of(context).colorScheme.inversePrimary,
//         // Here we take the value from the MyHomePage object that was created by
//         // the App.build method, and use it to set our appbar title.
//         title: Text(widget.title),
//         actions: [
//           MaterialButton(onPressed: (){
//             setState(() {
//               locationList.clear();
//             });
//           },child: const Text("清空"),)
//         ],
//       ),
//       body: ListView.builder(
//           itemBuilder: (ctx,i){
//             return Text("经度 ${locationList[i].longitude}  纬度 ${locationList[i].latitude}");
//           },
//           itemCount: locationList.length,
//           ),
//       floatingActionButton: FloatingActionButton(
//         onPressed: _incrementCounter,
//         tooltip: '查询定位',
//         child: const Icon(Icons.location_on_outlined),
//       ), // This trailing comma makes auto-formatting nicer for build methods.
//     );
//   }
//
//   String getList(){
//     var list = "";
//     for(int i=0;i<locationList.length;i++){
//       var value = locationList[i];
//       list += "${i+1} 经度 ${value.longitude}  纬度 ${value.latitude} \n";
//     }
//     return list;
//   }
// }
