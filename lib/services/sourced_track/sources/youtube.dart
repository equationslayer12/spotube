import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotify/spotify.dart';
import 'package:spotube/models/source_match.dart';
import 'package:spotube/services/sourced_track/enums.dart';
import 'package:spotube/services/sourced_track/exceptions.dart';
import 'package:spotube/services/sourced_track/models/source_info.dart';
import 'package:spotube/services/sourced_track/models/source_map.dart';
import 'package:spotube/services/sourced_track/models/video_info.dart';
import 'package:spotube/services/sourced_track/sourced_track.dart';
import 'package:spotube/utils/service_utils.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

final youtubeClient = YoutubeExplode();
final officialMusicRegex = RegExp(
  r"official\s(video|audio|music\svideo|lyric\svideo|visualizer)",
  caseSensitive: false,
);

class YoutubeSourceInfo extends SourceInfo {
  YoutubeSourceInfo({
    required super.id,
    required super.title,
    required super.artist,
    required super.thumbnail,
    required super.pageUrl,
    required super.duration,
    required super.artistUrl,
    required super.album,
  });
}

class YoutubeSourcedTrack extends SourcedTrack {
  YoutubeSourcedTrack({
    required super.source,
    required super.siblings,
    required super.sourceInfo,
    required super.track,
    required super.ref,
  });

  static Future<YoutubeSourcedTrack> fetchFromTrack({
    required Track track,
    required Ref ref,
  }) async {
    final cachedSource = await SourceMatch.box.get(track.id);

    if (cachedSource == null || cachedSource.sourceType != SourceType.youtube) {
      final siblings = await fetchSiblings(ref: ref, track: track);
      if (siblings.isEmpty) {
        throw TrackNotFoundException(track);
      }

      await SourceMatch.box.put(
        track.id!,
        SourceMatch(
          id: track.id!,
          sourceType: SourceType.youtube,
          createdAt: DateTime.now(),
          sourceId: siblings.first.info.id,
        ),
      );

      return YoutubeSourcedTrack(
        ref: ref,
        siblings: siblings.map((s) => s.info).skip(1).toList(),
        source: siblings.first.source as SourceMap,
        sourceInfo: siblings.first.info,
        track: track,
      );
    }
    final item = await youtubeClient.videos.get(cachedSource.sourceId);
    final manifest = await youtubeClient.videos.streamsClient.getManifest(
      cachedSource.sourceId,
    );
    return YoutubeSourcedTrack(
      ref: ref,
      siblings: [],
      source: toSourceMap(manifest),
      sourceInfo: YoutubeSourceInfo(
        id: item.id.value,
        artist: item.author,
        artistUrl: "https://www.youtube.com/channel/${item.channelId}",
        pageUrl: item.url,
        thumbnail: item.thumbnails.highResUrl,
        title: item.title,
        duration: item.duration ?? Duration.zero,
        album: null,
      ),
      track: track,
    );
  }

  static SourceMap toSourceMap(StreamManifest manifest) {
    var m4a = manifest.audioOnly
        .where((audio) => audio.codec.mimeType == "audio/mp4")
        .sortByBitrate();

    var weba = manifest.audioOnly
        .where((audio) => audio.codec.mimeType == "audio/webm")
        .sortByBitrate();

    m4a = m4a.isEmpty ? weba.toList() : m4a;
    weba = weba.isEmpty ? m4a.toList() : weba;

    return SourceMap(
      m4a: SourceQualityMap(
        high: m4a.first.url.toString(),
        medium: (m4a.elementAtOrNull(m4a.length ~/ 2) ?? m4a[1]).url.toString(),
        low: m4a.last.url.toString(),
      ),
      weba: SourceQualityMap(
        high: weba.first.url.toString(),
        medium:
            (weba.elementAtOrNull(weba.length ~/ 2) ?? weba[1]).url.toString(),
        low: weba.last.url.toString(),
      ),
    );
  }

  static Future<SiblingType> toSiblingType(
    int index,
    YoutubeVideoInfo item,
  ) async {
    SourceMap? sourceMap;
    if (index == 0) {
      final manifest =
          await youtubeClient.videos.streamsClient.getManifest(item.id);
      sourceMap = toSourceMap(manifest);
    }

    final SiblingType sibling = (
      info: YoutubeSourceInfo(
        id: item.id,
        artist: item.channelName,
        artistUrl: "https://www.youtube.com/channel/${item.channelId}",
        pageUrl: "https://www.youtube.com/watch?v=${item.id}",
        thumbnail: item.thumbnailUrl,
        title: item.title,
        duration: item.duration,
        album: null,
      ),
      source: sourceMap,
    );

    return sibling;
  }

  static List<YoutubeVideoInfo> rankResults(
      List<YoutubeVideoInfo> results, Track track) {
    final artists = (track.artists ?? [])
        .map((ar) => ar.name)
        .toList()
        .whereNotNull()
        .toList();

    return results
        .sorted((a, b) => b.views.compareTo(a.views))
        .map((sibling) {
          int score = 0;

          for (final artist in artists) {
            final isSameChannelArtist =
                sibling.channelName.toLowerCase() == artist.toLowerCase();
            final channelContainsArtist = sibling.channelName
                .toLowerCase()
                .contains(artist.toLowerCase());

            if (isSameChannelArtist || channelContainsArtist) {
              score += 1;
            }

            final titleContainsArtist =
                sibling.title.toLowerCase().contains(artist.toLowerCase());

            if (titleContainsArtist) {
              score += 1;
            }
          }

          final titleSameAsTrackName =
              sibling.title.toLowerCase() == track.name?.toLowerCase();

          final titleContainsTrackName =
              sibling.title.toLowerCase().contains(track.name!.toLowerCase());

          final trackNameContainsTitle =
              track.name!.toLowerCase().contains(sibling.title.toLowerCase());

          final hasOfficialFlag =
              officialMusicRegex.hasMatch(sibling.title.toLowerCase());

          if (titleSameAsTrackName) {
            score += 1;
          }

          if (titleContainsTrackName || trackNameContainsTitle) {
            score += 3;
          }

          if (hasOfficialFlag) {
            score += 1;
          }

          if (hasOfficialFlag && titleContainsTrackName) {
            score += 2;
          }

          return (sibling: sibling, score: score);
        })
        .sorted((a, b) => b.score.compareTo(a.score))
        .map((e) => e.sibling)
        .toList();
  }

  static Future<List<SiblingType>> fetchSiblings({
    required Track track,
    required Ref ref,
  }) async {
    final query = SourcedTrack.getSearchTerm(track);

    final searchResults = await youtubeClient.search.search(
      "$query - Topic",
      filter: TypeFilters.video,
    );

    if (ServiceUtils.onlyContainsEnglish(query)) {
      return await Future.wait(searchResults
          .map(YoutubeVideoInfo.fromVideo)
          .mapIndexed(toSiblingType));
    }

    final rankedSiblings = rankResults(
      searchResults.map(YoutubeVideoInfo.fromVideo).toList(),
      track,
    );

    return await Future.wait(rankedSiblings.mapIndexed(toSiblingType));
  }

  @override
  Future<YoutubeSourcedTrack?> swapWithSibling(SourceInfo sibling) async {
    if (sibling.id == sourceInfo.id) {
      return null;
    }

    // a sibling source that was fetched from the search results
    final isStepSibling = siblings.none((s) => s.id == sibling.id);

    final newSourceInfo = isStepSibling
        ? sibling
        : siblings.firstWhere((s) => s.id == sibling.id);
    final newSiblings = siblings.where((s) => s.id != sibling.id).toList()
      ..insert(0, sourceInfo);

    final manifest =
        await youtubeClient.videos.streamsClient.getManifest(newSourceInfo.id);

    await SourceMatch.box.put(
      id!,
      SourceMatch(
        id: id!,
        sourceType: SourceType.jiosaavn,
        createdAt: DateTime.now(),
        sourceId: newSourceInfo.id,
      ),
    );

    return YoutubeSourcedTrack(
      ref: ref,
      siblings: newSiblings,
      source: toSourceMap(manifest),
      sourceInfo: newSourceInfo,
      track: this,
    );
  }

  @override
  Future<YoutubeSourcedTrack> copyWithSibling() async {
    if (siblings.isNotEmpty) {
      return this;
    }
    final fetchedSiblings = await fetchSiblings(ref: ref, track: this);

    return YoutubeSourcedTrack(
      ref: ref,
      siblings: fetchedSiblings
          .where((s) => s.info.id != sourceInfo.id)
          .map((s) => s.info)
          .toList(),
      source: source,
      sourceInfo: sourceInfo,
      track: this,
    );
  }
}
