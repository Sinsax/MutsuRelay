class UserInfo {
  final int mid;
  final String uname;
  final bool isLogin;

  UserInfo({
    required this.mid,
    required this.uname,
    required this.isLogin,
  });

  factory UserInfo.fromJson(Map<String, dynamic> json) {
    return UserInfo(
      mid: json['mid'] as int,
      uname: json['uname'] as String,
      isLogin: json['is_login'] as bool,
    );
  }
}
