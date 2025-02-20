import 'dart:convert';

import 'package:json_annotation/json_annotation.dart';

@JsonSerializable()
class UserInfo {
  final String? login;
  final int? id;
  final String? nodeId;
  final String? avatarUrl;
  final String? gravatarId;
  final String? url;
  final String? htmlUrl;
  final String? followersUrl;
  final String? followingUrl;
  final String? gistsUrl;
  final String? starredUrl;
  final String? subscriptionsUrl;
  final String? organizationsUrl;
  final String? reposUrl;
  final String? eventsUrl;
  final String? receivedEventsUrl;
  final String? type;
  final bool? siteAdmin;
  final String? name;
  final String? company;
  final String? blog;
  final String? location;
  final String? email;
  final bool? hireable;
  final String? bio;
  final String? twitterUsername;
  final int? publicRepos;
  final int? publicGists;
  final int? followers;
  final int? following;
  final String? createdAt;
  final String? updatedAt;
  final int? privateGists;
  final int? totalPrivateRepos;
  final int? ownedPrivateRepos;
  final int? diskUsage;
  final int? collaborators;
  final bool? twoFactorAuthentication;

  const UserInfo({
    this.login,
    this.id,
    this.nodeId,
    this.avatarUrl,
    this.gravatarId,
    this.url,
    this.htmlUrl,
    this.followersUrl,
    this.followingUrl,
    this.gistsUrl,
    this.starredUrl,
    this.subscriptionsUrl,
    this.organizationsUrl,
    this.reposUrl,
    this.eventsUrl,
    this.receivedEventsUrl,
    this.type,
    this.siteAdmin,
    this.name,
    this.company,
    this.blog,
    this.location,
    this.email,
    this.hireable,
    this.bio,
    this.twitterUsername,
    this.publicRepos,
    this.publicGists,
    this.followers,
    this.following,
    this.createdAt,
    this.updatedAt,
    this.privateGists,
    this.totalPrivateRepos,
    this.ownedPrivateRepos,
    this.diskUsage,
    this.collaborators,
    this.twoFactorAuthentication,
  });

  @override
  String toString() {
    return 'UserInfo(login: $login, id: $id, nodeId: $nodeId, avatarUrl: $avatarUrl, gravatarId: $gravatarId, url: $url, htmlUrl: $htmlUrl, followersUrl: $followersUrl, followingUrl: $followingUrl, gistsUrl: $gistsUrl, starredUrl: $starredUrl, subscriptionsUrl: $subscriptionsUrl, organizationsUrl: $organizationsUrl, reposUrl: $reposUrl, eventsUrl: $eventsUrl, receivedEventsUrl: $receivedEventsUrl, type: $type, siteAdmin: $siteAdmin, name: $name, company: $company, blog: $blog, location: $location, email: $email, hireable: $hireable, bio: $bio, twitterUsername: $twitterUsername, publicRepos: $publicRepos, publicGists: $publicGists, followers: $followers, following: $following, createdAt: $createdAt, updatedAt: $updatedAt, privateGists: $privateGists, totalPrivateRepos: $totalPrivateRepos, ownedPrivateRepos: $ownedPrivateRepos, diskUsage: $diskUsage, collaborators: $collaborators, twoFactorAuthentication: $twoFactorAuthentication)';
  }

  factory UserInfo.fromMap(Map<String, dynamic> data) => UserInfo(
        login: data['login'] as String?,
        id: data['id'] as int?,
        nodeId: data['node_id'] as String?,
        avatarUrl: data['avatar_url'] as String?,
        gravatarId: data['gravatar_id'] as String?,
        url: data['url'] as String?,
        htmlUrl: data['html_url'] as String?,
        followersUrl: data['followers_url'] as String?,
        followingUrl: data['following_url'] as String?,
        gistsUrl: data['gists_url'] as String?,
        starredUrl: data['starred_url'] as String?,
        subscriptionsUrl: data['subscriptions_url'] as String?,
        organizationsUrl: data['organizations_url'] as String?,
        reposUrl: data['repos_url'] as String?,
        eventsUrl: data['events_url'] as String?,
        receivedEventsUrl: data['received_events_url'] as String?,
        type: data['type'] as String?,
        siteAdmin: data['site_admin'] as bool?,
        name: data['name'] as String?,
        company: data['company'] as String?,
        blog: data['blog'] as String?,
        location: data['location'] as String?,
        email: data['email'] as String?,
        hireable: data['hireable'] as bool?,
        bio: data['bio'] as String?,
        twitterUsername: data['twitter_username'] as String?,
        publicRepos: data['public_repos'] as int?,
        publicGists: data['public_gists'] as int?,
        followers: data['followers'] as int?,
        following: data['following'] as int?,
        createdAt: data['created_at'] as String?,
        updatedAt: data['updated_at'] as String?,
        privateGists: data['private_gists'] as int?,
        totalPrivateRepos: data['total_private_repos'] as int?,
        ownedPrivateRepos: data['owned_private_repos'] as int?,
        diskUsage: data['disk_usage'] as int?,
        collaborators: data['collaborators'] as int?,
        twoFactorAuthentication: data['two_factor_authentication'] as bool?,
      );

  Map<String, dynamic> toMap() => {
        'login': login,
        'id': id,
        'node_id': nodeId,
        'avatar_url': avatarUrl,
        'gravatar_id': gravatarId,
        'url': url,
        'html_url': htmlUrl,
        'followers_url': followersUrl,
        'following_url': followingUrl,
        'gists_url': gistsUrl,
        'starred_url': starredUrl,
        'subscriptions_url': subscriptionsUrl,
        'organizations_url': organizationsUrl,
        'repos_url': reposUrl,
        'events_url': eventsUrl,
        'received_events_url': receivedEventsUrl,
        'type': type,
        'site_admin': siteAdmin,
        'name': name,
        'company': company,
        'blog': blog,
        'location': location,
        'email': email,
        'hireable': hireable,
        'bio': bio,
        'twitter_username': twitterUsername,
        'public_repos': publicRepos,
        'public_gists': publicGists,
        'followers': followers,
        'following': following,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'private_gists': privateGists,
        'total_private_repos': totalPrivateRepos,
        'owned_private_repos': ownedPrivateRepos,
        'disk_usage': diskUsage,
        'collaborators': collaborators,
        'two_factor_authentication': twoFactorAuthentication,
      };

  /// `dart:convert`
  ///
  /// Parses the string and returns the resulting Json object as [UserInfo].
  factory UserInfo.fromJson(Map<String, dynamic> data) {
    return UserInfo.fromMap(data);
  }

  /// `dart:convert`
  ///
  /// Converts [UserInfo] to a JSON string.
  String toJson() => json.encode(toMap());

  factory UserInfo.fromJsonString(String jsonString) {
    return UserInfo.fromMap(json.decode(jsonString));
  }

  @override
  int get hashCode =>
      login.hashCode ^
      id.hashCode ^
      nodeId.hashCode ^
      avatarUrl.hashCode ^
      gravatarId.hashCode ^
      url.hashCode ^
      htmlUrl.hashCode ^
      followersUrl.hashCode ^
      followingUrl.hashCode ^
      gistsUrl.hashCode ^
      starredUrl.hashCode ^
      subscriptionsUrl.hashCode ^
      organizationsUrl.hashCode ^
      reposUrl.hashCode ^
      eventsUrl.hashCode ^
      receivedEventsUrl.hashCode ^
      type.hashCode ^
      siteAdmin.hashCode ^
      name.hashCode ^
      company.hashCode ^
      blog.hashCode ^
      location.hashCode ^
      email.hashCode ^
      hireable.hashCode ^
      bio.hashCode ^
      twitterUsername.hashCode ^
      publicRepos.hashCode ^
      publicGists.hashCode ^
      followers.hashCode ^
      following.hashCode ^
      createdAt.hashCode ^
      updatedAt.hashCode ^
      privateGists.hashCode ^
      totalPrivateRepos.hashCode ^
      ownedPrivateRepos.hashCode ^
      diskUsage.hashCode ^
      collaborators.hashCode ^
      twoFactorAuthentication.hashCode;
}
