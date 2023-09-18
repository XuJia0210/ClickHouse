#include <chrono>
#include <gtest/gtest.h>

#include <IO/Resource/tests/ResourceTest.h>

#include <IO/Resource/FairPolicy.h>
#include <IO/Resource/ThrottlerConstraint.h>
#include "IO/ISchedulerNode.h"
#include "IO/ResourceRequest.h"

using namespace DB;

using ResourceTest = ResourceTestClass;

TEST(IOResourceThrottlerConstraint, LeakyBucketConstraint)
{
    ResourceTest t;
    EventQueue::TimePoint start = std::chrono::system_clock::now();
    t.process(start, 0);

    t.add<ThrottlerConstraint>("/", "<max_burst>20.0</max_burst><max_speed>10.0</max_speed>");
    t.add<FifoQueue>("/A", "");

    t.enqueue("/A", {10, 10, 10, 10, 10, 10, 10, 10});

    t.process(start + std::chrono::seconds(0));
    t.consumed("A", 30); // It is allowed to go below zero for exactly one resource request

    t.process(start + std::chrono::seconds(1));
    t.consumed("A", 10);

    t.process(start + std::chrono::seconds(2));
    t.consumed("A", 10);

    t.process(start + std::chrono::seconds(3));
    t.consumed("A", 10);

    t.process(start + std::chrono::seconds(4));
    t.consumed("A", 10);

    t.process(start + std::chrono::seconds(100500));
    t.consumed("A", 10);
}

TEST(IOResourceThrottlerConstraint, BucketFilling)
{
    ResourceTest t;
    EventQueue::TimePoint start = std::chrono::system_clock::now();
    t.process(start, 0);

    t.add<ThrottlerConstraint>("/", "<max_burst>100.0</max_burst><max_speed>10.0</max_speed>");
    t.add<FifoQueue>("/A", "");

    t.enqueue("/A", {100});

    t.process(start + std::chrono::seconds(0));
    t.consumed("A", 100); // consume all tokens, but it is still active (not negative)

    t.process(start + std::chrono::seconds(5));
    t.consumed("A", 0); // There was nothing to consume

    t.enqueue("/A", {10, 10, 10, 10, 10, 10, 10, 10, 10, 10});
    t.process(start + std::chrono::seconds(5));
    t.consumed("A", 60); // 5 sec * 10 tokens/sec = 50 tokens + 1 extra request to go below zero

    t.process(start + std::chrono::seconds(100));
    t.consumed("A", 40); // Consume rest

    t.process(start + std::chrono::seconds(200));

    t.enqueue("/A", {95, 1, 1, 1, 1, 1, 1, 1, 1, 1});
    t.process(start + std::chrono::seconds(200));
    t.consumed("A", 101); // check we cannot consume more than max_burst + 1 request

    t.process(start + std::chrono::seconds(100500));
    t.consumed("A", 3);
}

TEST(IOResourceThrottlerConstraint, PeekAndAvgLimits)
{
    ResourceTest t;
    EventQueue::TimePoint start = std::chrono::system_clock::now();
    t.process(start, 0);

    // Burst = 100 token
    // Peek speed = 50 token/s for 10 seconds
    // Avg speed = 10 tokens/s afterwards
    t.add<ThrottlerConstraint>("/", "<max_burst>100.0</max_burst><max_speed>50.0</max_speed>");
    t.add<ThrottlerConstraint>("/avg", "<max_burst>5000.0</max_burst><max_speed>10.0</max_speed>");
    t.add<FifoQueue>("/avg/A", "");

    ResourceCost req_cost = 1;
    ResourceCost total_cost = 10000;
    for (int i = 0; i < total_cost / req_cost; i++)
        t.enqueue("/avg/A", {req_cost});

    double consumed = 0;
    for (int seconds = 0; seconds < 100; seconds++)
    {
        t.process(start + std::chrono::seconds(seconds));
        double arrival_curve = std::min(100.0 + 50.0 * seconds, 5000.0 + 10.0 * seconds) + req_cost;
        t.consumed("A", static_cast<ResourceCost>(arrival_curve - consumed));
        consumed = arrival_curve;
    }
}

TEST(IOResourceThrottlerConstraint, ThrottlerAndFairness)
{
    ResourceTest t;
    EventQueue::TimePoint start;
    start += EventQueue::Duration(1000000000);
    t.process(start, 0);

    t.add<ThrottlerConstraint>("/", "<max_burst>100.0</max_burst><max_speed>10.0</max_speed>");
    t.add<FairPolicy>("/fair", "");
    t.add<FifoQueue>("/fair/A", "<weight>10</weight>");
    t.add<FifoQueue>("/fair/B", "<weight>90</weight>");

    ResourceCost req_cost = 1;
    ResourceCost total_cost = 2000;
    for (int i = 0; i < total_cost / req_cost; i++)
    {
        t.enqueue("/fair/A", {req_cost});
        t.enqueue("/fair/B", {req_cost});
    }

    double shareA = 0.1;
    double shareB = 0.9;

    // Bandwidth-latency coupling due to fairness: worst latency is inversely proportional to share
    auto max_latencyA = static_cast<ResourceCost>(req_cost * (1.0 + 1.0 / shareA));
    auto max_latencyB = static_cast<ResourceCost>(req_cost * (1.0 + 1.0 / shareB));

    double consumedA = 0;
    double consumedB = 0;
    for (int seconds = 0; seconds < 100; seconds++)
    {
        t.process(start + std::chrono::seconds(seconds));
        double arrival_curve = 100.0 + 10.0 * seconds + req_cost;
        t.consumed("A", static_cast<ResourceCost>(arrival_curve * shareA - consumedA), max_latencyA);
        t.consumed("B", static_cast<ResourceCost>(arrival_curve * shareB - consumedB), max_latencyB);
        consumedA = arrival_curve * shareA;
        consumedB = arrival_curve * shareB;
    }
}
