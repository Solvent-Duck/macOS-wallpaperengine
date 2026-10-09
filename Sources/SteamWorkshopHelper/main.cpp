// SteamWorkshopHelper: a small separate process that talks to the Steam
// client through the user's own Steamworks SDK (libsteam_api.dylib, loaded at
// runtime) on behalf of the app, as Wallpaper Engine (app 431960).
//
// It runs in its own process so a fault in libsteam_api can't take the
// renderer down, and so the app can end the Steam session (and the
// "In-game" status) by letting it exit.
//
// Protocol: commands arrive on stdin, one per line:
//   download <id> | subscribe <id> | unsubscribe <id> | details <id> [<id>...]
//   browse request=<n> sort=<trend|popular|recent|subscribed> page=<n> days=<n>
//          types=<A,B> ratings=<A,B> tag=<T> text=<percent-encoded>
//   vote <id> up|down | getvote <id> | favorite <id> | unfavorite <id> | favorites
//   refresh | quit
// Events go to stdout as one JSON object per line, each with an "event" key.
// End of stdin (the app went away) also quits.

#include <dlfcn.h>
#include <unistd.h>

#include <atomic>
#include <cmath>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <iostream>
#include <map>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "steam/steam_api_flat.h"

namespace {

constexpr AppId_t kAppID = 431960;

// MARK: - libsteam_api, resolved by name

struct SteamAPI {
    decltype(&SteamAPI_InitFlat) InitFlat;
    decltype(&SteamAPI_Shutdown) Shutdown;
    decltype(&SteamAPI_GetHSteamPipe) GetHSteamPipe;
    decltype(&SteamAPI_ManualDispatch_Init) ManualDispatch_Init;
    decltype(&SteamAPI_ManualDispatch_RunFrame) ManualDispatch_RunFrame;
    decltype(&SteamAPI_ManualDispatch_GetNextCallback) ManualDispatch_GetNextCallback;
    decltype(&SteamAPI_ManualDispatch_FreeLastCallback) ManualDispatch_FreeLastCallback;
    decltype(&SteamAPI_ManualDispatch_GetAPICallResult) ManualDispatch_GetAPICallResult;
    decltype(&SteamAPI_SteamUGC_v021) SteamUGC;
    decltype(&SteamAPI_SteamApps_v009) SteamApps;
    decltype(&SteamAPI_SteamUser_v023) SteamUser;
    decltype(&SteamAPI_ISteamApps_BIsSubscribedApp) BIsSubscribedApp;
    decltype(&SteamAPI_ISteamUser_GetSteamID) GetSteamID;
    decltype(&SteamAPI_ISteamUGC_GetNumSubscribedItems) GetNumSubscribedItems;
    decltype(&SteamAPI_ISteamUGC_GetSubscribedItems) GetSubscribedItems;
    decltype(&SteamAPI_ISteamUGC_GetItemState) GetItemState;
    decltype(&SteamAPI_ISteamUGC_GetItemInstallInfo) GetItemInstallInfo;
    decltype(&SteamAPI_ISteamUGC_GetItemDownloadInfo) GetItemDownloadInfo;
    decltype(&SteamAPI_ISteamUGC_DownloadItem) DownloadItem;
    decltype(&SteamAPI_ISteamUGC_SubscribeItem) SubscribeItem;
    decltype(&SteamAPI_ISteamUGC_UnsubscribeItem) UnsubscribeItem;
    decltype(&SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest) CreateQueryUGCDetailsRequest;
    decltype(&SteamAPI_ISteamUGC_SendQueryUGCRequest) SendQueryUGCRequest;
    decltype(&SteamAPI_ISteamUGC_GetQueryUGCResult) GetQueryUGCResult;
    decltype(&SteamAPI_ISteamUGC_GetQueryUGCPreviewURL) GetQueryUGCPreviewURL;
    decltype(&SteamAPI_ISteamUGC_ReleaseQueryUGCRequest) ReleaseQueryUGCRequest;
    decltype(&SteamAPI_ISteamUGC_CreateQueryAllUGCRequestPage) CreateQueryAllUGCRequestPage;
    decltype(&SteamAPI_ISteamUGC_AddRequiredTag) AddRequiredTag;
    decltype(&SteamAPI_ISteamUGC_AddRequiredTagGroup) AddRequiredTagGroup;
    decltype(&SteamAPI_ISteamUGC_SetSearchText) SetSearchText;
    decltype(&SteamAPI_ISteamUGC_SetRankedByTrendDays) SetRankedByTrendDays;
    decltype(&SteamAPI_ISteamUGC_SetReturnLongDescription) SetReturnLongDescription;
    decltype(&SteamAPI_ISteamUGC_GetQueryUGCStatistic) GetQueryUGCStatistic;
    decltype(&SteamAPI_ISteamUGC_SetUserItemVote) SetUserItemVote;
    decltype(&SteamAPI_ISteamUGC_GetUserItemVote) GetUserItemVote;
    decltype(&SteamAPI_ISteamUGC_AddItemToFavorites) AddItemToFavorites;
    decltype(&SteamAPI_ISteamUGC_RemoveItemFromFavorites) RemoveItemFromFavorites;
    decltype(&SteamAPI_ISteamUGC_CreateQueryUserUGCRequest) CreateQueryUserUGCRequest;
    decltype(&SteamAPI_ISteamUGC_SetReturnOnlyIDs) SetReturnOnlyIDs;
};

std::string loadError;

template <typename T>
bool resolve(void *library, const char *name, T &slot) {
    slot = reinterpret_cast<T>(dlsym(library, name));
    if (!slot && loadError.empty()) loadError = std::string("missing symbol ") + name;
    return slot != nullptr;
}

bool load(const char *path, SteamAPI &api) {
    void *library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        const char *error = dlerror();
        loadError = error ? error : "dlopen failed";
        return false;
    }
#define RESOLVE(field, symbol) ok &= resolve(library, #symbol, api.field)
    bool ok = true;
    RESOLVE(InitFlat, SteamAPI_InitFlat);
    RESOLVE(Shutdown, SteamAPI_Shutdown);
    RESOLVE(GetHSteamPipe, SteamAPI_GetHSteamPipe);
    RESOLVE(ManualDispatch_Init, SteamAPI_ManualDispatch_Init);
    RESOLVE(ManualDispatch_RunFrame, SteamAPI_ManualDispatch_RunFrame);
    RESOLVE(ManualDispatch_GetNextCallback, SteamAPI_ManualDispatch_GetNextCallback);
    RESOLVE(ManualDispatch_FreeLastCallback, SteamAPI_ManualDispatch_FreeLastCallback);
    RESOLVE(ManualDispatch_GetAPICallResult, SteamAPI_ManualDispatch_GetAPICallResult);
    RESOLVE(SteamUGC, SteamAPI_SteamUGC_v021);
    RESOLVE(SteamApps, SteamAPI_SteamApps_v009);
    RESOLVE(SteamUser, SteamAPI_SteamUser_v023);
    RESOLVE(BIsSubscribedApp, SteamAPI_ISteamApps_BIsSubscribedApp);
    RESOLVE(GetSteamID, SteamAPI_ISteamUser_GetSteamID);
    RESOLVE(GetNumSubscribedItems, SteamAPI_ISteamUGC_GetNumSubscribedItems);
    RESOLVE(GetSubscribedItems, SteamAPI_ISteamUGC_GetSubscribedItems);
    RESOLVE(GetItemState, SteamAPI_ISteamUGC_GetItemState);
    RESOLVE(GetItemInstallInfo, SteamAPI_ISteamUGC_GetItemInstallInfo);
    RESOLVE(GetItemDownloadInfo, SteamAPI_ISteamUGC_GetItemDownloadInfo);
    RESOLVE(DownloadItem, SteamAPI_ISteamUGC_DownloadItem);
    RESOLVE(SubscribeItem, SteamAPI_ISteamUGC_SubscribeItem);
    RESOLVE(UnsubscribeItem, SteamAPI_ISteamUGC_UnsubscribeItem);
    RESOLVE(CreateQueryUGCDetailsRequest, SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest);
    RESOLVE(SendQueryUGCRequest, SteamAPI_ISteamUGC_SendQueryUGCRequest);
    RESOLVE(GetQueryUGCResult, SteamAPI_ISteamUGC_GetQueryUGCResult);
    RESOLVE(GetQueryUGCPreviewURL, SteamAPI_ISteamUGC_GetQueryUGCPreviewURL);
    RESOLVE(ReleaseQueryUGCRequest, SteamAPI_ISteamUGC_ReleaseQueryUGCRequest);
    RESOLVE(CreateQueryAllUGCRequestPage, SteamAPI_ISteamUGC_CreateQueryAllUGCRequestPage);
    RESOLVE(AddRequiredTag, SteamAPI_ISteamUGC_AddRequiredTag);
    RESOLVE(AddRequiredTagGroup, SteamAPI_ISteamUGC_AddRequiredTagGroup);
    RESOLVE(SetSearchText, SteamAPI_ISteamUGC_SetSearchText);
    RESOLVE(SetRankedByTrendDays, SteamAPI_ISteamUGC_SetRankedByTrendDays);
    RESOLVE(SetReturnLongDescription, SteamAPI_ISteamUGC_SetReturnLongDescription);
    RESOLVE(GetQueryUGCStatistic, SteamAPI_ISteamUGC_GetQueryUGCStatistic);
    RESOLVE(SetUserItemVote, SteamAPI_ISteamUGC_SetUserItemVote);
    RESOLVE(GetUserItemVote, SteamAPI_ISteamUGC_GetUserItemVote);
    RESOLVE(AddItemToFavorites, SteamAPI_ISteamUGC_AddItemToFavorites);
    RESOLVE(RemoveItemFromFavorites, SteamAPI_ISteamUGC_RemoveItemFromFavorites);
    RESOLVE(CreateQueryUserUGCRequest, SteamAPI_ISteamUGC_CreateQueryUserUGCRequest);
    RESOLVE(SetReturnOnlyIDs, SteamAPI_ISteamUGC_SetReturnOnlyIDs);
#undef RESOLVE
    return ok;
}

// MARK: - Output

std::string quoted(const std::string &text) {
    std::string out = "\"";
    for (unsigned char c : text) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char buffer[8];
                snprintf(buffer, sizeof buffer, "\\u%04x", c);
                out += buffer;
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    return out + "\"";
}

std::string idString(PublishedFileId_t id) { return quoted(std::to_string(id)); }

void emit(const std::string &json) {
    fputs(json.c_str(), stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

[[noreturn]] void fail(const char *code, const std::string &message, int status) {
    emit("{\"event\":\"error\",\"code\":" + quoted(code) + ",\"message\":" + quoted(message) + "}");
    exit(status);
}

/// Decode `%XX` escapes in a command value.
std::string percentDecoded(const std::string &text) {
    std::string out;
    for (size_t i = 0; i < text.size(); i++) {
        if (text[i] == '%' && i + 2 < text.size() && isxdigit(text[i + 1]) && isxdigit(text[i + 2])) {
            out += static_cast<char>(std::stoi(text.substr(i + 1, 2), nullptr, 16));
            i += 2;
        } else {
            out += text[i];
        }
    }
    return out;
}

std::vector<std::string> split(const std::string &text, char separator) {
    std::vector<std::string> parts;
    std::string part;
    std::istringstream in(text);
    while (std::getline(in, part, separator)) {
        if (!part.empty()) parts.push_back(part);
    }
    return parts;
}

// MARK: - Commands from stdin

std::mutex commandLock;
std::deque<std::string> commands;
std::atomic<bool> inputClosed{false};

void readCommands() {
    std::string line;
    while (std::getline(std::cin, line)) {
        std::lock_guard<std::mutex> guard(commandLock);
        commands.push_back(line);
    }
    inputClosed = true;
}

bool nextCommand(std::string &line) {
    std::lock_guard<std::mutex> guard(commandLock);
    if (commands.empty()) return false;
    line = commands.front();
    commands.pop_front();
    return true;
}

// MARK: - Session

struct Session {
    SteamAPI &api;
    ISteamUGC *ugc;
    HSteamPipe pipe;
    std::set<PublishedFileId_t> watched; // items whose progress is reported
    struct PendingCall {
        int expected;
        UGCQueryHandle_t query;
        long request; // browse request number, echoed back
        bool favorites = false; // a page of the account's favorites list
        uint32 page = 0;
    };
    std::vector<std::string> favoriteIDs; // accumulated across favorites pages
    std::map<SteamAPICall_t, PendingCall> pendingCalls;

    std::string itemJSON(PublishedFileId_t id) {
        uint32 state = api.GetItemState(ugc, id);
        uint64 size = 0;
        uint32 timestamp = 0;
        char folder[4096] = {0};
        bool installed = api.GetItemInstallInfo(ugc, id, &size, folder, sizeof folder, &timestamp);
        std::ostringstream out;
        out << "{\"id\":" << idString(id) << ",\"state\":" << state
            << ",\"folder\":" << quoted(installed ? folder : "")
            << ",\"size\":" << size << ",\"timeUpdated\":" << timestamp << "}";
        return out.str();
    }

    std::vector<PublishedFileId_t> subscribedItems() {
        uint32 count = api.GetNumSubscribedItems(ugc, false);
        std::vector<PublishedFileId_t> ids(count);
        if (count) ids.resize(api.GetSubscribedItems(ugc, ids.data(), count, false));
        return ids;
    }

    /// Report every subscription. `settled` is false when Steam still reports
    /// none, which right after Steam starts means "not loaded yet".
    void emitSubscriptions(bool settled) {
        auto ids = subscribedItems();
        std::string json = "{\"event\":\"subscriptions\",\"settled\":";
        json += (settled || !ids.empty()) ? "true" : "false";
        json += ",\"items\":[";
        for (size_t i = 0; i < ids.size(); i++) {
            if (i) json += ",";
            json += itemJSON(ids[i]);
            uint32 state = api.GetItemState(ugc, ids[i]);
            if (state & (k_EItemStateDownloading | k_EItemStateDownloadPending)) watched.insert(ids[i]);
        }
        emit(json + "]}");
    }

    void emitProgress() {
        for (auto it = watched.begin(); it != watched.end();) {
            PublishedFileId_t id = *it;
            uint32 state = api.GetItemState(ugc, id);
            uint64 downloaded = 0, total = 0;
            api.GetItemDownloadInfo(ugc, id, &downloaded, &total);
            std::ostringstream out;
            out << "{\"event\":\"progress\",\"id\":" << idString(id) << ",\"state\":" << state
                << ",\"downloaded\":" << downloaded << ",\"total\":" << total << "}";
            emit(out.str());
            bool busy = state & (k_EItemStateDownloading | k_EItemStateDownloadPending | k_EItemStateNeedsUpdate);
            it = busy ? std::next(it) : watched.erase(it);
        }
    }

    void handle(const std::string &line) {
        std::istringstream in(line);
        std::string verb;
        in >> verb;
        std::vector<PublishedFileId_t> ids;
        for (unsigned long long id; in >> id;) ids.push_back(id);

        if (verb == "quit") {
            api.Shutdown();
            exit(0);
        } else if (verb == "refresh") {
            emitSubscriptions(true);
        } else if (verb == "download") {
            for (auto id : ids) {
                bool ok = api.DownloadItem(ugc, id, true);
                if (ok) watched.insert(id);
                emit("{\"event\":\"downloadStarted\",\"id\":" + idString(id) + ",\"ok\":" + (ok ? "true" : "false") + "}");
            }
        } else if (verb == "subscribe" || verb == "unsubscribe") {
            bool subscribe = verb == "subscribe";
            for (auto id : ids) {
                SteamAPICall_t call = subscribe ? api.SubscribeItem(ugc, id) : api.UnsubscribeItem(ugc, id);
                int expected = subscribe ? RemoteStorageSubscribePublishedFileResult_t::k_iCallback
                                         : RemoteStorageUnsubscribePublishedFileResult_t::k_iCallback;
                if (call != k_uAPICallInvalid) pendingCalls[call] = {expected, k_UGCQueryHandleInvalid, -1};
            }
        } else if (verb == "details" && !ids.empty()) {
            UGCQueryHandle_t query = api.CreateQueryUGCDetailsRequest(ugc, ids.data(), static_cast<uint32>(ids.size()));
            SteamAPICall_t call = api.SendQueryUGCRequest(ugc, query);
            if (call != k_uAPICallInvalid) pendingCalls[call] = {SteamUGCQueryCompleted_t::k_iCallback, query, -1};
            else api.ReleaseQueryUGCRequest(ugc, query);
        } else if (verb == "browse") {
            browse(line);
        } else if (verb == "vote" && ids.size() == 1) {
            bool up = line.find(" up") != std::string::npos;
            track(api.SetUserItemVote(ugc, ids[0], up), SetUserItemVoteResult_t::k_iCallback, ids[0]);
        } else if (verb == "getvote") {
            for (auto id : ids) track(api.GetUserItemVote(ugc, id), GetUserItemVoteResult_t::k_iCallback, id);
        } else if (verb == "favorite" || verb == "unfavorite") {
            for (auto id : ids) {
                SteamAPICall_t call = verb == "favorite" ? api.AddItemToFavorites(ugc, kAppID, id)
                                                        : api.RemoveItemFromFavorites(ugc, kAppID, id);
                track(call, UserFavoriteItemsListChanged_t::k_iCallback, id);
            }
        } else if (verb == "favorites") {
            favoriteIDs.clear();
            requestFavorites(1);
        } else if (!verb.empty()) {
            emit("{\"event\":\"error\",\"code\":\"badCommand\",\"message\":" + quoted(line) + "}");
        }
    }

    /// Remember an async call; `id` is reported back even if the call fails
    /// and its result struct is empty.
    void track(SteamAPICall_t call, int expected, PublishedFileId_t id) {
        if (call != k_uAPICallInvalid) pendingCalls[call] = {expected, k_UGCQueryHandleInvalid, static_cast<long>(id)};
    }

    /// The account's Workshop favorites for this app, one page at a time.
    void requestFavorites(uint32 page) {
        AccountID_t account = static_cast<AccountID_t>(api.GetSteamID(api.SteamUser()) & 0xFFFFFFFFull);
        UGCQueryHandle_t query = api.CreateQueryUserUGCRequest(ugc, account, k_EUserUGCList_Favorited, k_EUGCMatchingUGCType_Items,
                                                               k_EUserUGCListSortOrder_CreationOrderDesc, kAppID, kAppID, page);
        api.SetReturnOnlyIDs(ugc, query, true);
        SteamAPICall_t call = api.SendQueryUGCRequest(ugc, query);
        if (call == k_uAPICallInvalid) {
            api.ReleaseQueryUGCRequest(ugc, query);
            emit("{\"event\":\"favorites\",\"result\":2,\"ids\":[]}");
            return;
        }
        PendingCall pending{SteamUGCQueryCompleted_t::k_iCallback, query, -1};
        pending.favorites = true;
        pending.page = page;
        pendingCalls[call] = pending;
    }

    /// One page of the Workshop catalogue. Tag groups require at least one
    /// tag from each group (e.g. a Scene, Video or Web item rated Everyone).
    void browse(const std::string &line) {
        std::map<std::string, std::string> options;
        std::istringstream in(line);
        std::string word;
        in >> word; // "browse"
        while (in >> word) {
            auto equals = word.find('=');
            if (equals != std::string::npos) options[word.substr(0, equals)] = percentDecoded(word.substr(equals + 1));
        }
        long request = options.count("request") ? std::atol(options["request"].c_str()) : 0;
        uint32 page = options.count("page") ? static_cast<uint32>(std::max(1, std::atoi(options["page"].c_str()))) : 1;
        std::string sort = options["sort"], text = options["text"];

        EUGCQuery queryType = k_EUGCQuery_RankedByTrend;
        if (!text.empty()) queryType = k_EUGCQuery_RankedByTextSearch;
        else if (sort == "popular") queryType = k_EUGCQuery_RankedByVote;
        else if (sort == "recent") queryType = k_EUGCQuery_RankedByPublicationDate;
        else if (sort == "subscribed") queryType = k_EUGCQuery_RankedByTotalUniqueSubscriptions;

        UGCQueryHandle_t query = api.CreateQueryAllUGCRequestPage(ugc, queryType, k_EUGCMatchingUGCType_Items_ReadyToUse, kAppID, kAppID, page);
        if (query == k_UGCQueryHandleInvalid) {
            emit("{\"event\":\"browseResults\",\"request\":" + std::to_string(request) + ",\"result\":2,\"total\":0,\"items\":[]}");
            return;
        }
        if (queryType == k_EUGCQuery_RankedByTrend) {
            api.SetRankedByTrendDays(ugc, query, options.count("days") ? static_cast<uint32>(std::atoi(options["days"].c_str())) : 7);
        }
        if (!text.empty()) api.SetSearchText(ugc, query, text.c_str());
        for (const char *group : {"types", "ratings"}) {
            auto tags = split(options[group], ',');
            if (tags.empty()) continue;
            std::vector<const char *> pointers;
            for (auto &tag : tags) pointers.push_back(tag.c_str());
            SteamParamStringArray_t array{pointers.data(), static_cast<int32>(pointers.size())};
            api.AddRequiredTagGroup(ugc, query, &array);
        }
        if (!options["tag"].empty()) api.AddRequiredTag(ugc, query, options["tag"].c_str());
        api.SetReturnLongDescription(ugc, query, true);

        SteamAPICall_t call = api.SendQueryUGCRequest(ugc, query);
        if (call == k_uAPICallInvalid) {
            api.ReleaseQueryUGCRequest(ugc, query);
            emit("{\"event\":\"browseResults\",\"request\":" + std::to_string(request) + ",\"result\":2,\"total\":0,\"items\":[]}");
            return;
        }
        pendingCalls[call] = {SteamUGCQueryCompleted_t::k_iCallback, query, request};
    }

    /// One query result as JSON, plus this account's state for the item.
    std::string queryItemJSON(UGCQueryHandle_t query, uint32 index, bool full) {
        SteamUGCDetails_t details;
        if (!api.GetQueryUGCResult(ugc, query, index, &details)) return "";
        char preview[1024] = {0};
        api.GetQueryUGCPreviewURL(ugc, query, index, preview, sizeof preview);
        std::ostringstream item;
        item << "{\"id\":" << idString(details.m_nPublishedFileId)
             << ",\"result\":" << details.m_eResult << ",\"title\":" << quoted(details.m_rgchTitle)
             << ",\"tags\":" << quoted(details.m_rgchTags) << ",\"preview\":" << quoted(preview)
             << ",\"fileSize\":" << static_cast<uint32>(details.m_nFileSize);
        if (full) {
            uint64 subscriptions = 0;
            api.GetQueryUGCStatistic(ugc, query, index, k_EItemStatistic_NumUniqueSubscriptions, &subscriptions);
            item << ",\"description\":" << quoted(details.m_rgchDescription)
                 << ",\"votesUp\":" << details.m_unVotesUp << ",\"votesDown\":" << details.m_unVotesDown
                 << ",\"score\":" << (std::isfinite(details.m_flScore) ? details.m_flScore : 0.0f) << ",\"subscriptions\":" << subscriptions
                 << ",\"timeUpdated\":" << details.m_rtimeUpdated
                 << ",\"state\":" << api.GetItemState(ugc, details.m_nPublishedFileId);
        }
        return item.str() + "}";
    }

    void handleCallResult(const SteamAPICallCompleted_t &completed) {
        auto pending = pendingCalls.find(completed.m_hAsyncCall);
        if (pending == pendingCalls.end()) return;
        PendingCall info = pending->second;
        int expected = info.expected;
        UGCQueryHandle_t query = info.query;
        long request = info.request;
        pendingCalls.erase(pending);
        std::vector<uint8> buffer(completed.m_cubParam);
        bool failed = true;
        bool ok = api.ManualDispatch_GetAPICallResult(pipe, completed.m_hAsyncCall, buffer.data(),
                                                      static_cast<int>(buffer.size()), expected, &failed);
        if (info.favorites) {
            auto *result = reinterpret_cast<SteamUGCQueryCompleted_t *>(buffer.data());
            bool succeeded = ok && !failed && result->m_eResult == k_EResultOK;
            if (succeeded) {
                for (uint32 i = 0; i < result->m_unNumResultsReturned; i++) {
                    SteamUGCDetails_t details;
                    if (api.GetQueryUGCResult(ugc, query, i, &details)) favoriteIDs.push_back(idString(details.m_nPublishedFileId));
                }
            }
            api.ReleaseQueryUGCRequest(ugc, query);
            if (succeeded && result->m_unNumResultsReturned >= kNumUGCResultsPerPage && info.page < 100) {
                requestFavorites(info.page + 1);
                return;
            }
            std::string json = "{\"event\":\"favorites\",\"result\":" + std::to_string(succeeded ? int(k_EResultOK) : int(k_EResultFail)) + ",\"ids\":[";
            for (size_t i = 0; i < favoriteIDs.size(); i++) json += (i ? "," : "") + favoriteIDs[i];
            emit(json + "]}");
            return;
        }
        if (expected == SetUserItemVoteResult_t::k_iCallback) {
            auto *result = reinterpret_cast<SetUserItemVoteResult_t *>(buffer.data());
            int code = (ok && !failed) ? result->m_eResult : k_EResultFail;
            emit("{\"event\":\"voteResult\",\"id\":" + idString(static_cast<PublishedFileId_t>(request)) + ",\"result\":" + std::to_string(code)
                 + ",\"up\":" + (result->m_bVoteUp ? "true" : "false") + "}");
            return;
        }
        if (expected == GetUserItemVoteResult_t::k_iCallback) {
            auto *result = reinterpret_cast<GetUserItemVoteResult_t *>(buffer.data());
            int code = (ok && !failed) ? result->m_eResult : k_EResultFail;
            emit("{\"event\":\"userVote\",\"id\":" + idString(static_cast<PublishedFileId_t>(request)) + ",\"result\":" + std::to_string(code)
                 + ",\"up\":" + (result->m_bVotedUp ? "true" : "false") + ",\"down\":" + (result->m_bVotedDown ? "true" : "false") + "}");
            return;
        }
        if (expected == UserFavoriteItemsListChanged_t::k_iCallback) {
            auto *result = reinterpret_cast<UserFavoriteItemsListChanged_t *>(buffer.data());
            int code = (ok && !failed) ? result->m_eResult : k_EResultFail;
            emit("{\"event\":\"favoriteResult\",\"id\":" + idString(static_cast<PublishedFileId_t>(request)) + ",\"result\":" + std::to_string(code)
                 + ",\"added\":" + (result->m_bWasAddRequest ? "true" : "false") + "}");
            return;
        }
        if (expected == SteamUGCQueryCompleted_t::k_iCallback) {
            auto *result = reinterpret_cast<SteamUGCQueryCompleted_t *>(buffer.data());
            bool succeeded = ok && !failed && result->m_eResult == k_EResultOK;
            bool browsing = request >= 0;
            std::string json = browsing
                ? "{\"event\":\"browseResults\",\"request\":" + std::to_string(request)
                  + ",\"result\":" + std::to_string(succeeded ? int(k_EResultOK) : int(ok && !failed ? result->m_eResult : k_EResultFail))
                  + ",\"total\":" + std::to_string(succeeded ? result->m_unTotalMatchingResults : 0) + ",\"items\":["
                : "{\"event\":\"details\",\"items\":[";
            if (succeeded) {
                bool first = true;
                for (uint32 i = 0; i < result->m_unNumResultsReturned; i++) {
                    std::string item = queryItemJSON(query, i, browsing);
                    if (item.empty()) continue;
                    json += (first ? "" : ",") + item;
                    first = false;
                }
            }
            emit(json + "]}");
            api.ReleaseQueryUGCRequest(ugc, query);
        } else {
            // Both subscribe results share this layout.
            auto *result = reinterpret_cast<RemoteStorageSubscribePublishedFileResult_t *>(buffer.data());
            const char *kind = expected == RemoteStorageSubscribePublishedFileResult_t::k_iCallback ? "subscribeResult" : "unsubscribeResult";
            int code = (ok && !failed) ? result->m_eResult : k_EResultFail;
            emit(std::string("{\"event\":\"") + kind + "\",\"id\":" + idString(result->m_nPublishedFileId)
                 + ",\"result\":" + std::to_string(code) + "}");
        }
    }

    void dispatchCallbacks() {
        api.ManualDispatch_RunFrame(pipe);
        CallbackMsg_t message;
        while (api.ManualDispatch_GetNextCallback(pipe, &message)) {
            switch (message.m_iCallback) {
            case SteamAPICallCompleted_t::k_iCallback:
                handleCallResult(*reinterpret_cast<SteamAPICallCompleted_t *>(message.m_pubParam));
                break;
            case ItemInstalled_t::k_iCallback: {
                auto *installed = reinterpret_cast<ItemInstalled_t *>(message.m_pubParam);
                if (installed->m_unAppID == kAppID) {
                    emit("{\"event\":\"installed\",\"item\":" + itemJSON(installed->m_nPublishedFileId) + "}");
                }
                break;
            }
            case DownloadItemResult_t::k_iCallback: {
                auto *result = reinterpret_cast<DownloadItemResult_t *>(message.m_pubParam);
                if (result->m_unAppID == kAppID) {
                    watched.erase(result->m_nPublishedFileId);
                    emit("{\"event\":\"downloadResult\",\"id\":" + idString(result->m_nPublishedFileId)
                         + ",\"result\":" + std::to_string(result->m_eResult) + "}");
                }
                break;
            }
            case RemoteStoragePublishedFileSubscribed_t::k_iCallback: {
                auto *item = reinterpret_cast<RemoteStoragePublishedFileSubscribed_t *>(message.m_pubParam);
                if (item->m_nAppID == kAppID) emit("{\"event\":\"subscribed\",\"id\":" + idString(item->m_nPublishedFileId) + "}");
                break;
            }
            case RemoteStoragePublishedFileUnsubscribed_t::k_iCallback: {
                auto *item = reinterpret_cast<RemoteStoragePublishedFileUnsubscribed_t *>(message.m_pubParam);
                if (item->m_nAppID == kAppID) emit("{\"event\":\"unsubscribed\",\"id\":" + idString(item->m_nPublishedFileId) + "}");
                break;
            }
            default:
                break;
            }
            api.ManualDispatch_FreeLastCallback(pipe);
        }
    }
};

} // namespace

int main(int argc, char **argv) {
    const char *libraryPath = nullptr;
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], "--steam-api") == 0) libraryPath = argv[i + 1];
    }
    if (!libraryPath) fail("usage", "usage: SteamWorkshopHelper --steam-api <path to libsteam_api.dylib>", 64);

    SteamAPI api{};
    if (!load(libraryPath, api)) fail("sdkMissing", loadError, 2);

    setenv("SteamAppId", "431960", 1);
    setenv("SteamGameId", "431960", 1);
    SteamErrMsg message = {0};
    ESteamAPIInitResult result = api.InitFlat(&message);
    if (result == k_ESteamAPIInitResult_NoSteamClient) fail("steamNotRunning", message, 3);
    if (result != k_ESteamAPIInitResult_OK) fail("initFailed", message, 3);
    api.ManualDispatch_Init();

    if (!api.BIsSubscribedApp(api.SteamApps(), kAppID)) {
        api.Shutdown();
        fail("notOwned", "This Steam account doesn't own Wallpaper Engine.", 4);
    }

    Session session{api, api.SteamUGC(), api.GetHSteamPipe()};
    emit("{\"event\":\"ready\",\"steamID\":" + quoted(std::to_string(api.GetSteamID(api.SteamUser()))) + "}");

    std::thread(readCommands).detach();

    // Steam fills in the subscription list a few seconds after it starts;
    // until then it reports none. Wait up to 30 s for it.
    auto started = std::chrono::steady_clock::now();
    bool reported = false;
    auto lastProgress = started;
    while (true) {
        session.dispatchCallbacks();
        auto now = std::chrono::steady_clock::now();
        if (!reported) {
            bool timedOut = now - started > std::chrono::seconds(30);
            if (api.GetNumSubscribedItems(session.ugc, false) > 0 || timedOut) {
                session.emitSubscriptions(timedOut);
                reported = true;
            }
        }
        std::string line;
        while (nextCommand(line)) session.handle(line);
        if (inputClosed) {
            while (nextCommand(line)) session.handle(line);
            session.handle("quit");
        }
        if (now - lastProgress > std::chrono::seconds(1)) {
            session.emitProgress();
            lastProgress = now;
        }
        usleep(100000);
    }
}
