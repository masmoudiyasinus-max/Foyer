import 'package:flutter_test/flutter_test.dart';
import 'package:foyer/models/family_member.dart';
import 'package:foyer/models/announcement.dart';
import 'package:foyer/models/invitation.dart';
import 'package:foyer/models/task_item.dart';
import 'package:foyer/models/family_event.dart';

void main() {
  group('Domain Models & Monogram Tests', () {
    test('FamilyMember extracts uppercase initial monogram correctly', () {
      const member1 = FamilyMember(id: '1', name: 'Maman');
      const member2 = FamilyMember(id: '2', name: 'cuisine');
      const member3 = FamilyMember(id: '3', name: ' Ahmed ');
      const member4 = FamilyMember(id: '4', name: '');

      expect(member1.monogram, 'M');
      expect(member2.monogram, 'C');
      expect(member3.monogram, 'A');
      expect(member4.monogram, '?');
    });

    test('FamilyMember serialization and deserialization preserves all fields', () {
      final member = FamilyMember(
        id: 'dev_12345',
        name: 'Papa',
        ip: '192.168.1.50',
        port: 54443,
        isOnline: true,
        isApproved: true,
        lastSeen: DateTime(2026, 9, 20, 15, 30),
        phoneNumber: '+33 6 98 76 54 32',
        birthDate: '10 Août 1980',
        timetableDocumentPath: '/docs/planning.pdf',
      );

      final map = member.toMap();
      final reconstructed = FamilyMember.fromMap(map);

      expect(reconstructed.id, member.id);
      expect(reconstructed.name, member.name);
      expect(reconstructed.ip, member.ip);
      expect(reconstructed.port, member.port);
      expect(reconstructed.isOnline, isTrue);
      expect(reconstructed.isApproved, isTrue);
      expect(reconstructed.phoneNumber, member.phoneNumber);
      expect(reconstructed.birthDate, member.birthDate);
      expect(reconstructed.timetableDocumentPath, member.timetableDocumentPath);
    });

    test('Announcement model serialization', () {
      final banner = Announcement(
        id: 'b1',
        title: 'Dîner de famille',
        text: 'Rendez-vous à 20h au salon',
        url: 'https://example.com/menu',
        createdAt: DateTime(2026, 9, 20),
      );

      final map = banner.toMap();
      final reconstructed = Announcement.fromMap(map);

      expect(reconstructed.title, 'Dîner de famille');
      expect(reconstructed.text, 'Rendez-vous à 20h au salon');
      expect(reconstructed.url, 'https://example.com/menu');
    });

    test('Invitation model preserves static date & time display', () {
      final inv = Invitation(
        id: 'inv_1',
        title: 'Remise des diplômes',
        description: 'Cérémonie officielle',
        dateTimeDisplay: 'Samedi 24 Octobre à 19:30',
        rsvpResponses: {'dev_1': true, 'dev_2': false},
        createdAt: DateTime(2026, 9, 20),
      );

      final map = inv.toMap();
      final reconstructed = Invitation.fromMap(map);

      expect(reconstructed.dateTimeDisplay, 'Samedi 24 Octobre à 19:30');
      expect(reconstructed.rsvpResponses['dev_1'], isTrue);
      expect(reconstructed.rsvpResponses['dev_2'], isFalse);
    });

    test('FamilyMeetingEvent and EventComment nested chat serialization', () {
      final comment = EventComment(
        id: 'c1',
        authorId: 'dev_1',
        authorName: 'Sarah',
        text: 'Je serai là à l\'heure !',
        timestamp: DateTime(2026, 9, 20, 14, 0),
      );

      final event = FamilyMeetingEvent(
        id: 'evt_1',
        title: 'Conseil de famille',
        location: 'Salon principal',
        dateTimeDisplay: 'Dimanche 25 Octobre à 15:00',
        comments: [comment],
        createdAt: DateTime(2026, 9, 20),
      );

      final map = event.toMap();
      final reconstructed = FamilyMeetingEvent.fromMap(map);

      expect(reconstructed.title, 'Conseil de famille');
      expect(reconstructed.comments.length, 1);
      expect(reconstructed.comments.first.authorName, 'Sarah');
      expect(reconstructed.comments.first.authorMonogram, 'S');
      expect(reconstructed.comments.first.text, 'Je serai là à l\'heure !');
    });
  });

  group('Automated Midnight Purge Evaluator Tests', () {
    test('Identifies and purges completed tasks from previous days', () {
      final now = DateTime.now();
      final startOfToday = DateTime(now.year, now.month, now.day);
      final yesterday = startOfToday.subtract(const Duration(hours: 3));

      final taskDoneYesterday = TaskItem(
        id: 'task_yesterday',
        title: 'Sortir les poubelles',
        isDone: true,
        completedAt: yesterday,
        createdAt: yesterday.subtract(const Duration(hours: 2)),
      );

      final taskDoneToday = TaskItem(
        id: 'task_today',
        title: 'Acheter du pain',
        isDone: true,
        completedAt: now,
        createdAt: now.subtract(const Duration(minutes: 30)),
      );

      final taskPending = TaskItem(
        id: 'task_pending',
        title: 'Nettoyer le garage',
        isDone: false,
        createdAt: now,
      );

      final List<TaskItem> allTasks = [taskDoneYesterday, taskDoneToday, taskPending];

      // Pure algorithmic midnight purge evaluation logic:
      final List<String> purgedIds = [];
      for (final task in allTasks) {
        if (task.isDone && task.completedAt != null) {
          if (task.completedAt!.isBefore(startOfToday)) {
            purgedIds.add(task.id);
          }
        }
      }

      expect(purgedIds, contains('task_yesterday'));
      expect(purgedIds, isNot(contains('task_today')));
      expect(purgedIds, isNot(contains('task_pending')));
      expect(purgedIds.length, 1);
    });
  });
}
