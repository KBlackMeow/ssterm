import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/views/sftp_view.dart';

void main() {
  group('sftpEntryRank', () {
    test('directory ranks 0', () {
      expect(
        sftpEntryRank(isDirectory: true, isSymbolicLink: false),
        equals(0),
      );
    });

    test('symlink ranks 1', () {
      expect(
        sftpEntryRank(isDirectory: false, isSymbolicLink: true),
        equals(1),
      );
    });

    test('regular file ranks 2', () {
      expect(
        sftpEntryRank(isDirectory: false, isSymbolicLink: false),
        equals(2),
      );
    });

    test('dir sorts before symlink', () {
      final dir = sftpEntryRank(isDirectory: true, isSymbolicLink: false);
      final link = sftpEntryRank(isDirectory: false, isSymbolicLink: true);
      expect(dir, lessThan(link));
    });

    test('symlink sorts before regular file', () {
      final link = sftpEntryRank(isDirectory: false, isSymbolicLink: true);
      final file = sftpEntryRank(isDirectory: false, isSymbolicLink: false);
      expect(link, lessThan(file));
    });

    test('dir sorts before regular file', () {
      final dir = sftpEntryRank(isDirectory: true, isSymbolicLink: false);
      final file = sftpEntryRank(isDirectory: false, isSymbolicLink: false);
      expect(dir, lessThan(file));
    });
  });

  group('sftpJoin', () {
    test('joins root with name', () {
      expect(sftpJoin('/', 'home'), equals('/home'));
    });

    test('joins path without trailing slash', () {
      expect(sftpJoin('/home', 'user'), equals('/home/user'));
    });

    test('joins path with trailing slash', () {
      expect(sftpJoin('/home/', 'user'), equals('/home/user'));
    });

    test('joins nested path', () {
      expect(sftpJoin('/home/user', 'docs'), equals('/home/user/docs'));
    });
  });

  group('sftpParent', () {
    test('root stays root', () {
      expect(sftpParent('/'), equals('/'));
    });

    test('top-level dir returns root', () {
      expect(sftpParent('/home'), equals('/'));
    });

    test('second-level dir returns parent', () {
      expect(sftpParent('/home/user'), equals('/home'));
    });

    test('third-level dir returns grandparent', () {
      expect(sftpParent('/home/user/docs'), equals('/home/user'));
    });

    test('path with trailing content returns correct parent', () {
      expect(sftpParent('/var/log/nginx'), equals('/var/log'));
    });
  });

  group('sftpJoin + sftpParent roundtrip', () {
    test('joining then going parent returns original dir', () {
      const dir = '/home/user';
      final joined = sftpJoin(dir, 'file.txt');
      expect(sftpParent(joined), equals(dir));
    });

    test('root join then parent returns root', () {
      final joined = sftpJoin('/', 'tmp');
      expect(sftpParent(joined), equals('/'));
    });
  });
}
