import 'package:flutter/material.dart';

class AppStoreHomePage extends StatelessWidget {
  const AppStoreHomePage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.background,
      body: SafeArea(
        child: Column(
          children: [
            // 顶部应用栏
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '软件商店',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w500,
                      color: colorScheme.onBackground,
                    ),
                  ),
                  CircleAvatar(
                    backgroundColor: const Color(0xFFE8DEF8),
                    radius: 20,
                    child: Text(
                      '用',
                      style: TextStyle(
                        fontSize: 18,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 主内容区域
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 搜索栏
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20.0, vertical: 16.0),
                      child: Container(
                        height: 56,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8DEF8),
                          borderRadius: BorderRadius.circular(28),
                        ),
                        child: Row(
                          children: [
                            const SizedBox(width: 16),
                            Icon(
                              Icons.search,
                              color: colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              '搜索应用和游戏...',
                              style: TextStyle(
                                fontSize: 16,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // 导航标签栏
                    SizedBox(
                      height: 48,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _buildTabItem('应用', true, colorScheme),
                            _buildTabItem('游戏', false, colorScheme),
                            _buildTabItem('电影', false, colorScheme),
                            _buildTabItem('音乐', false, colorScheme),
                            _buildTabItem('图书', false, colorScheme),
                          ],
                        ),
                      ),
                    ),

                    // 特色横幅
                    Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Container(
                        height: 160,
                        decoration: BoxDecoration(
                          color: const Color(0xFFEADDFF),
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 3,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.all(20.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '2025年最热门应用',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w500,
                                color: colorScheme.onBackground,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '探索本月推荐应用',
                              style: TextStyle(
                                fontSize: 14,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: () {},
                              style: ElevatedButton.styleFrom(
                                backgroundColor: colorScheme.primary,
                                foregroundColor: Colors.white,
                                minimumSize: const Size(120, 40),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                              ),
                              child: const Text('立即获取',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w500)),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // 指示器点
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFFCAC4D0),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFFCAC4D0),
                          ),
                        ),
                      ],
                    ),

                    // 热门应用标题
                    Padding(
                      padding:
                          const EdgeInsets.fromLTRB(20.0, 20.0, 20.0, 16.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '热门应用',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w500,
                              color: colorScheme.onBackground,
                            ),
                          ),
                          Text(
                            '更多',
                            style: TextStyle(
                              fontSize: 14,
                              color: colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // 热门应用卡片列表
                    SizedBox(
                      height: 190,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        children: [
                          _buildAppCard('设计大师', '设计工具', '4.8 ★', 'A',
                              const Color(0xFFD0BCFF), const Color(0xFF381E72)),
                          _buildAppCard('音乐创作', '音频编辑', '4.9 ★', 'B',
                              const Color(0xFFFFB4AB), const Color(0xFF601410)),
                          _buildAppCard('账本宝', '财务管理', '4.7 ★', 'C',
                              const Color(0xFFA8DAB5), const Color(0xFF1D592E)),
                        ],
                      ),
                    ),

                    // 推荐应用标题
                    Padding(
                      padding:
                          const EdgeInsets.fromLTRB(20.0, 20.0, 20.0, 16.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '为您推荐',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w500,
                              color: colorScheme.onBackground,
                            ),
                          ),
                          Text(
                            '更多',
                            style: TextStyle(
                              fontSize: 14,
                              color: colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // 推荐应用列表
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20.0),
                      child: Container(
                        height: 80,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 2,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            const SizedBox(width: 10),
                            // 应用图标
                            Container(
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(
                                color: const Color(0xFFEADDFF),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Center(
                                child: Text(
                                  'D',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: colorScheme.primary,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            // 应用信息
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    '学习助手',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                      color: colorScheme.onBackground,
                                    ),
                                  ),
                                  Text(
                                    '教育工具 | 4.9 ★',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // 下载按钮
                            Container(
                              width: 50,
                              height: 40,
                              decoration: BoxDecoration(
                                color: const Color(0xFFE8DEF8),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Center(
                                child: Text(
                                  '获取',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: colorScheme.primary,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                        ),
                      ),
                    ),

                    // 添加底部间距，确保内容与底部导航栏不重叠
                    const SizedBox(height: 80),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: colorScheme.background,
        selectedItemColor: colorScheme.primary,
        unselectedItemColor: const Color(0xFF79747E),
        currentIndex: 0,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: '首页',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bar_chart_outlined),
            label: '排行榜',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.category_outlined),
            label: '分类',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.update_outlined),
            label: '更新',
          ),
        ],
      ),
    );
  }

  Widget _buildTabItem(String title, bool isSelected, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
              color: isSelected
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          if (isSelected)
            Container(
              width: 30,
              height: 3,
              decoration: BoxDecoration(
                color: colorScheme.primary,
                borderRadius: BorderRadius.circular(1.5),
              ),
            )
        ],
      ),
    );
  }

  Widget _buildAppCard(String title, String category, String rating,
      String letter, Color bgColor, Color textColor) {
    return Container(
      width: 110,
      margin: const EdgeInsets.symmetric(horizontal: 5.0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 应用图标
          Container(
            margin: const EdgeInsets.all(10),
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Center(
              child: Text(
                letter,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
            ),
          ),
          // 应用信息
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF1F1F1F),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  category,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF49454F),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  rating,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF6750A4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
