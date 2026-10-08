#include <Common/RemoteHostFilter.h>
#include <Common/Exception.h>

#include <Poco/AutoPtr.h>
#include <Poco/DOM/DOMParser.h>
#include <Poco/URI.h>
#include <Poco/Util/XMLConfiguration.h>

#include <gtest/gtest.h>

namespace
{

Poco::AutoPtr<Poco::Util::XMLConfiguration> parseConfig(const std::string & xml)
{
    Poco::XML::DOMParser dom_parser;
    Poco::AutoPtr<Poco::XML::Document> document = dom_parser.parseString(xml);
    return new Poco::Util::XMLConfiguration(document);
}

}

TEST(RemoteHostFilter, MalformedReloadKeepsPreviousValues)
{
    DB::RemoteHostFilter filter;

    auto good_config = parseConfig(R"CONFIG(<clickhouse>
    <remote_url_allow_hosts>
        <host>allowed.com</host>
        <host_regexp>^.*\.allowed-regexp\.com$</host_regexp>
        <s3_bucket>s3.example.com/my-bucket</s3_bucket>
    </remote_url_allow_hosts>
</clickhouse>)CONFIG");
    filter.setValuesFromConfig(*good_config);

    auto check_previous_values = [&]
    {
        EXPECT_NO_THROW(filter.checkURL(Poco::URI("http://allowed.com/path")));
        EXPECT_NO_THROW(filter.checkURL(Poco::URI("http://sub.allowed-regexp.com/path")));
        EXPECT_TRUE(filter.isBucketAllowed("s3.example.com", 443, "my-bucket"));
        EXPECT_FALSE(filter.isBucketAllowed("s3.example.com", 443, "other-bucket"));
        EXPECT_THROW(filter.checkURL(Poco::URI("http://new.com/path")), DB::Exception);
    };
    check_previous_values();

    auto bad_config = parseConfig(R"CONFIG(<clickhouse>
    <remote_url_allow_hosts>
        <host>new.com</host>
        <s3_bucket>no-bucket</s3_bucket>
        <host>allowed.com</host>
        <host_regexp>^.*\.allowed-regexp\.com$</host_regexp>
        <s3_bucket>s3.example.com/my-bucket</s3_bucket>
    </remote_url_allow_hosts>
</clickhouse>)CONFIG");
    EXPECT_THROW(filter.setValuesFromConfig(*bad_config), DB::Exception);
    check_previous_values();

    auto empty_config = parseConfig("<clickhouse></clickhouse>");
    filter.setValuesFromConfig(*empty_config);
    EXPECT_NO_THROW(filter.checkURL(Poco::URI("http://new.com/path")));
    EXPECT_TRUE(filter.isBucketAllowed("s3.example.com", 443, "other-bucket"));
}
