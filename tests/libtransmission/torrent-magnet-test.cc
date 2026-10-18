// This file Copyright (C) 2022 Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <cstddef> // size_t
#include <future>
#include <string>
#include <string_view>

#include <gtest/gtest.h>

#include <libtransmission/error.h>
#include <libtransmission/torrent-magnet.h>
#include <libtransmission/torrent-metainfo.h>

#include "test-fixtures.h"

namespace tr::test
{

namespace
{
// info dict of a 3-file torrent whose v1 hash is fa5794674a18241bec985ddc3390e3cb171345e4
auto constexpr InfoDictBase64 =
    "ZDU6ZmlsZXNsZDY6bGVuZ3RoaTEwNDg1NzZlNDpwYXRobDc6MTA0ODU3NmVlZDY6bGVuZ3RoaTQw"
    "OTZlNDpwYXRobDQ6NDA5NmVlZDY6bGVuZ3RoaTUxMmU0OnBhdGhsMzo1MTJlZWU0Om5hbWUyNDpm"
    "aWxlcy1maWxsZWQtd2l0aC16ZXJvZXMxMjpwaWVjZSBsZW5ndGhpMzI3NjhlNjpwaWVjZXM2NjA6"
    "UYhDGEm0YTFS/XvbpqP/Ck/WQktRiEMYSbRhMVL9e9umo/8KT9ZCS1GIQxhJtGExUv1726aj/wpP"
    "1kJLUYhDGEm0YTFS/XvbpqP/Ck/WQktRiEMYSbRhMVL9e9umo/8KT9ZCS1GIQxhJtGExUv1726aj"
    "/wpP1kJLUYhDGEm0YTFS/XvbpqP/Ck/WQktRiEMYSbRhMVL9e9umo/8KT9ZCS1GIQxhJtGExUv17"
    "26aj/wpP1kJLUYhDGEm0YTFS/XvbpqP/Ck/WQktRiEMYSbRhMVL9e9umo/8KT9ZCS1GIQxhJtGEx"
    "Uv1726aj/wpP1kJLUYhDGEm0YTFS/XvbpqP/Ck/WQktRiEMYSbRhMVL9e9umo/8KT9ZCS1GIQxhJ"
    "tGExUv1726aj/wpP1kJLUYhDGEm0YTFS/XvbpqP/Ck/WQktRiEMYSbRhMVL9e9umo/8KT9ZCS1GI"
    "QxhJtGExUv1726aj/wpP1kJLUYhDGEm0YTFS/XvbpqP/Ck/WQktRiEMYSbRhMVL9e9umo/8KT9ZC"
    "S1GIQxhJtGExUv1726aj/wpP1kJLUYhDGEm0YTFS/XvbpqP/Ck/WQktRiEMYSbRhMVL9e9umo/8K"
    "T9ZCS1GIQxhJtGExUv1726aj/wpP1kJLUYhDGEm0YTFS/XvbpqP/Ck/WQktRiEMYSbRhMVL9e9um"
    "o/8KT9ZCS1GIQxhJtGExUv1726aj/wpP1kJLUYhDGEm0YTFS/XvbpqP/Ck/WQktRiEMYSbRhMVL9"
    "e9umo/8KT9ZCS1GIQxhJtGExUv1726aj/wpP1kJLUYhDGEm0YTFS/XvbpqP/Ck/WQktRiEMYSbRh"
    "MVL9e9umo/8KT9ZCSzpX+QPk899JzAVbjTNoaVd8IP9dNzpwcml2YXRlaTBlZQ==";
} // namespace

using TorrentMagnetTest = SessionTest;

TEST_F(TorrentMagnetTest, getMetadataPiece)
{
    auto* tor = zeroTorrentInit(ZeroTorrentState::Complete);
    EXPECT_NE(nullptr, tor);

    auto benc = std::string{
        "d8:announce31:http://www.example.com/announce10:created by25:Transmission/2.61 (13407)13:creation datei1358704075e8:encoding5:UTF-84:info"
    };
    auto piece = 0;
    auto info_dict_size = size_t{ 0U };
    for (;;)
    {
        auto data = tor->get_metadata_piece(piece++);
        if (!data)
        {
            break;
        }

        benc.append(reinterpret_cast<char const*>(std::data(*data)), std::size(*data));
        info_dict_size += std::size(*data);
    }
    benc.append("e");
    EXPECT_EQ(tor->info_dict_size(), info_dict_size);

    auto torrent_metainfo = tr_torrent_metainfo{};
    auto error = tr_error{};
    EXPECT_TRUE(torrent_metainfo.parse_benc(benc, &error));
    EXPECT_FALSE(error) << error.message();

    EXPECT_EQ(tor->piece_hash(0), torrent_metainfo.piece_hash(0));
}

TEST_F(TorrentMagnetTest, setMetadataPiece)
{
    auto* const tor = zeroTorrentMagnetInit();
    EXPECT_NE(nullptr, tor);
    EXPECT_FALSE(tor->has_metainfo());

    auto const metainfo_benc = tr_base64_decode(InfoDictBase64);
    auto const metainfo_size = std::size(metainfo_benc);
    EXPECT_LE(metainfo_size, MetadataPieceSize);
    session_->run_in_session_thread(
        [&]()
        {
            tor->maybe_start_metadata_transfer(metainfo_size);
            tor->set_metadata_piece(0, std::data(metainfo_benc), metainfo_size);
        });

    EXPECT_TRUE(waitFor([tor] { return tor->has_metainfo(); }, 5s));
    EXPECT_EQ(tor->info_dict_size(), metainfo_size);
    EXPECT_EQ(tor->get_metadata_percent(), 1.0);
}

TEST_F(TorrentMagnetTest, setMetadataPieceKeepsWebseeds)
{
    tr_sessionSetKeepMagnetWebseedsEnabled(session_, true);

    static auto constexpr Magnet =
        "magnet:?xt=urn:btih:fa5794674a18241bec985ddc3390e3cb171345e4"
        "&ws=http%3A%2F%2Fwww.example.com%2Fpath%2F"sv;
    static auto constexpr Webseed = "http://www.example.com/path/"sv;

    auto* const ctor = tr_ctorNew(session_);
    EXPECT_TRUE(ctor->set_metainfo_from_magnet_link(Magnet));
    tr_ctorSetPaused(ctor, TR_FORCE, true);
    auto* const tor = tr_torrentNew(ctor, nullptr);
    tr_ctorFree(ctor);
    ASSERT_NE(nullptr, tor);
    EXPECT_FALSE(tor->has_metainfo());
    EXPECT_EQ(1U, tor->webseed_count());

    auto const metainfo_benc = tr_base64_decode(InfoDictBase64);
    auto const metainfo_size = std::size(metainfo_benc);
    session_->run_in_session_thread(
        [&]()
        {
            tor->maybe_start_metadata_transfer(metainfo_size);
            tor->set_metadata_piece(0, std::data(metainfo_benc), metainfo_size);
        });
    ASSERT_TRUE(waitFor([tor] { return tor->has_metainfo(); }, 5s));

    ASSERT_EQ(1U, tor->webseed_count());
    EXPECT_EQ(Webseed, tor->webseed(0));

    auto saved = tr_torrent_metainfo{};
    auto error = tr_error{};
    ASSERT_TRUE(saved.parse_torrent_file(tor->torrent_file(), nullptr, &error)) << error.message();
    ASSERT_EQ(1U, saved.webseed_count());
    EXPECT_EQ(Webseed, saved.webseed(0));
}

TEST_F(TorrentMagnetTest, setMetadataPieceDropsWebseedsByDefault)
{
    // The default keeps the old behaviour: the ws= webseeds are dropped once
    // the metadata arrives.
    EXPECT_FALSE(tr_sessionIsKeepMagnetWebseedsEnabled(session_));

    static auto constexpr Magnet =
        "magnet:?xt=urn:btih:fa5794674a18241bec985ddc3390e3cb171345e4"
        "&ws=http%3A%2F%2Fwww.example.com%2Fpath%2F"sv;

    auto* const ctor = tr_ctorNew(session_);
    EXPECT_TRUE(ctor->set_metainfo_from_magnet_link(Magnet));
    tr_ctorSetPaused(ctor, TR_FORCE, true);
    auto* const tor = tr_torrentNew(ctor, nullptr);
    tr_ctorFree(ctor);
    ASSERT_NE(nullptr, tor);
    EXPECT_FALSE(tor->has_metainfo());
    EXPECT_EQ(1U, tor->webseed_count());

    auto const metainfo_benc = tr_base64_decode(InfoDictBase64);
    auto const metainfo_size = std::size(metainfo_benc);
    session_->run_in_session_thread(
        [&]()
        {
            tor->maybe_start_metadata_transfer(metainfo_size);
            tor->set_metadata_piece(0, std::data(metainfo_benc), metainfo_size);
        });
    ASSERT_TRUE(waitFor([tor] { return tor->has_metainfo(); }, 5s));

    EXPECT_EQ(0U, tor->webseed_count());

    auto saved = tr_torrent_metainfo{};
    auto error = tr_error{};
    ASSERT_TRUE(saved.parse_torrent_file(tor->torrent_file(), nullptr, &error)) << error.message();
    EXPECT_EQ(0U, saved.webseed_count());
}

} // namespace tr::test
