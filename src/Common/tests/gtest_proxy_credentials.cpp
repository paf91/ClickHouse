#include <gtest/gtest.h>

#include <Common/ProxyConfiguration.h>
#include <Poco/URI.h>

namespace DB
{

TEST(ProxyCredentials, ParseUserInfo)
{
    /// Empty userinfo means no credentials at all.
    {
        const auto [username, password] = ProxyConfiguration::parseUserInfo("");
        ASSERT_EQ(username, "");
        ASSERT_EQ(password, "");
    }

    /// Username and password.
    {
        const auto [username, password] = ProxyConfiguration::parseUserInfo("user:password");
        ASSERT_EQ(username, "user");
        ASSERT_EQ(password, "password");
    }

    /// Username only, no separator.
    {
        const auto [username, password] = ProxyConfiguration::parseUserInfo("user");
        ASSERT_EQ(username, "user");
        ASSERT_EQ(password, "");
    }

    /// Trailing separator, empty password.
    {
        const auto [username, password] = ProxyConfiguration::parseUserInfo("user:");
        ASSERT_EQ(username, "user");
        ASSERT_EQ(password, "");
    }

    /// No username. Poco does not send an Authorization header in this case.
    {
        const auto [username, password] = ProxyConfiguration::parseUserInfo(":password");
        ASSERT_EQ(username, "");
        ASSERT_EQ(password, "password");
    }

    /// A password may contain colons. Only the first one separates.
    {
        const auto [username, password] = ProxyConfiguration::parseUserInfo("user:pass:word");
        ASSERT_EQ(username, "user");
        ASSERT_EQ(password, "pass:word");
    }
}

TEST(ProxyCredentials, UserInfoIsNotDecodedByPocoURI)
{
    /// `EnvironmentProxyConfigurationResolver` percent-decodes the username and the password itself,
    /// after splitting the userinfo on the first colon. This relies on `Poco::URI` keeping the userinfo
    /// verbatim when parsing a URI string, otherwise credentials would be decoded twice and an encoded
    /// colon would be taken for the separator.
    const Poco::URI uri("http://user:p%2541ss%3Aword@proxy:3128");
    ASSERT_EQ(uri.getUserInfo(), "user:p%2541ss%3Aword");

    const auto [username, password] = ProxyConfiguration::parseUserInfo(uri.getUserInfo());
    ASSERT_EQ(username, "user");
    ASSERT_EQ(password, "p%2541ss%3Aword");

    std::string decoded_password;
    Poco::URI::decode(password, decoded_password);
    ASSERT_EQ(decoded_password, "p%41ss:word");
}

}
