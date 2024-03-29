import 'dart:convert';

import 'package:stronzflix/backend/api/media.dart';
import 'package:stronzflix/backend/api/player.dart';
import 'package:stronzflix/backend/api/site.dart';
import 'package:stronzflix/utils/simple_http.dart' as http;

class StreamingCommunity extends Site {
    
    static Site instance = StreamingCommunity._("https://streamingcommunity.li");

    final String _cdn;
    final Map<String, String> _inhertia;

    StreamingCommunity._(String url)
        : _cdn = url.replaceFirst("//", "//cdn."), _inhertia = {}, super("StreamingCommunity", url);

    @override
    Future<void> prepare() async {
        await this.getInhertia();
    }

    Future<void> getInhertia() async {
        String body = await http.get(super.url);
        RegExpMatch match = RegExp(r'version&quot;:&quot;(?<inertia>[a-z0-9]+)&quot;').firstMatch(body)!;
        this._inhertia["X-Inertia"] = "true";
        this._inhertia["X-Inertia-Version"] = match.namedGroup("inertia")!;
    }

    Future<List<SearchResult>> _fetch(String url) async {
        String body = await http.get("${super.url}${url}", headers: this._inhertia);
        dynamic json = jsonDecode(body);
        dynamic titles = json["props"]["titles"];

        List<SearchResult> results = [];
        for (dynamic title in titles) {
            String poster = title["images"].firstWhere((dynamic image) => image["type"] == "poster")["filename"];

            results.add(SearchResult(
                site: this,
                name: title["name"],
                siteUrl: "/titles/${title["id"]}-${title["slug"]}",
                poster:  "${this._cdn}/images/${poster}" 
            ));
        }

        return results;
    }

    @override
    Future<List<SearchResult>> search(String query) {
        return this._fetch("/search?q=${Uri.encodeQueryComponent(query)}");
    }

    @override
    Future<List<SearchResult>> latests() {
        return this._fetch("/browse/latest");
    }

    Future<List<Episode>> getEpisodes(Series series, String seasonUrl) async {
        String body = await http.get("${super.url}${seasonUrl}", headers: this._inhertia);
        dynamic json = jsonDecode(body);

        dynamic season = json["props"]["loadedSeason"];
        dynamic titleId = json["props"]["title"]["id"];

        List<Episode> episodes = [];
        for(dynamic episode in season["episodes"]) {
            String cover = episode["images"].firstWhere((dynamic image) => image["type"] == "cover")["filename"];

            episodes.add(Episode(
                playerUrl: "/watch/${titleId}?e=${episode["id"]}",
                name: episode["name"],
                cover: "${this._cdn}/images/${cover}",
                player: Player.get("VixxCloud")!,
                series: series
            ));
        }

        return episodes;
    }

    Future<Series> getSeries(String url, dynamic title) async {
        return await Series.fromEpisodes(
            name: title["name"],
            generator: (series) async {
                List<List<Episode>> seasons = [];

                for(dynamic season in title["seasons"]) {
                    String seasonUrl = "${url}/stagione-${season["number"]}";
                    seasons.add(await this.getEpisodes(series, seasonUrl));
                }

                return seasons;
            }
        );
    }

    Film getFilm(dynamic title) {
        String cover = title["images"].firstWhere((dynamic image) => image["type"] == "poster")["filename"];
        return Film(
            name: title["name"],
            playerUrl: "/watch/${title["id"]}",
            player: Player.get("VixxCloud")!,
            cover: "${this._cdn}/images/${cover}"
        );
    }
    
    @override
    Future<Title> getTitle(SearchResult result) async {
        String body = await http.get("${super.url}${result.siteUrl}", headers: this._inhertia);
        dynamic json = jsonDecode(body);

        dynamic title = json["props"]["title"];

        if(title["type"] == "tv")
            return await this.getSeries(result.siteUrl, title);
        else
            return this.getFilm(title);
    }

    Future<String> parseVixCloud(String url) async {
        String data = await http.get(url);

        String playlistUrl = RegExp(r"url: '(.+?)'").firstMatch(data)!.group(1)!;

        String jsonString = RegExp(r"params: ({(.|\n)+?}),").firstMatch(data)!.group(1)!;
        jsonString = jsonString.replaceAll("'", '"').replaceAll(" ", "").replaceAll("\n", "").replaceAll("\",}", "\"}");
        dynamic json = jsonDecode(jsonString);

        String param = json.keys.map((key) => "$key=${json[key]}").join("&");
        String playlist = "${playlistUrl}?${param}";

        return playlist;
    }
}
