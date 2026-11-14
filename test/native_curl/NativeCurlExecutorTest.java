package com.github.pacalini.pica_comic;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

public final class NativeCurlExecutorTest {
    private static void check(boolean ok, String message) {
        if (!ok) throw new AssertionError(message);
    }

    private static void await(CountDownLatch latch) {
        try {
            check(latch.await(5, TimeUnit.SECONDS), "Timed out waiting for worker");
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new AssertionError(error);
        }
    }

    private static void rejects(Runnable action) {
        try {
            action.run();
            throw new AssertionError("Expected bounded executor to reject request");
        } catch (RejectedExecutionException expected) {
            // Capacity and shutdown must both produce an explicit rejection.
        }
    }

    public static void main(String[] args) throws Exception {
        boundedConcurrency();
        priorityAndQueuedCancel();
        destroyCancelsRunningAndWaiting();
        System.out.println("Native curl executor: capacity, priority, cancellation, destruction passed");
    }

    private static void boundedConcurrency() throws Exception {
        NativeCurlExecutor executor = new NativeCurlExecutor(2, 3);
        CountDownLatch started = new CountDownLatch(2);
        CountDownLatch release = new CountDownLatch(1);
        AtomicInteger active = new AtomicInteger();
        AtomicInteger peak = new AtomicInteger();
        AtomicInteger finished = new AtomicInteger();
        Runnable action = () -> {
            peak.accumulateAndGet(active.incrementAndGet(), Math::max);
            started.countDown();
            await(release);
            active.decrementAndGet();
        };
        try {
            for (int i = 0; i < 5; i++) {
                executor.submit("capacity-" + i, 0, action, () -> {}, finished::incrementAndGet);
            }
            await(started);
            rejects(() -> executor.submit("overflow", 0, action, () -> {}, () -> {}));
            check(executor.requestCount() == 5, "Admission exceeded the configured capacity");
            check(peak.get() == 2, "Worker count is not bounded");
        } finally {
            release.countDown();
            executor.close();
        }
        check(executor.awaitTermination(5, TimeUnit.SECONDS), "Workers did not stop");
        check(finished.get() == 5 && executor.requestCount() == 0,
                "Completed/cancelled entries were retained");
    }

    private static void priorityAndQueuedCancel() throws Exception {
        NativeCurlExecutor executor = new NativeCurlExecutor(1, 4);
        CountDownLatch started = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        CountDownLatch completed = new CountDownLatch(3);
        List<String> order = Collections.synchronizedList(new ArrayList<>());
        AtomicInteger cancelled = new AtomicInteger();
        AtomicInteger cancelledCleanup = new AtomicInteger();
        try {
            executor.submit("blocker", 0, () -> {
                started.countDown();
                await(release);
            }, () -> {}, () -> {});
            await(started);
            executor.submit("background", 0, () -> order.add("background"), () -> {}, completed::countDown);
            executor.submit("cancelled", 2, () -> {
                throw new AssertionError("Cancelled waiting request executed");
            }, cancelled::incrementAndGet, cancelledCleanup::incrementAndGet);
            executor.submit("visible-first", 2, () -> order.add("visible-first"), () -> {}, completed::countDown);
            executor.submit("visible-second", 2, () -> order.add("visible-second"), () -> {}, completed::countDown);
            executor.cancel("cancelled");
            executor.cancel("cancelled");
            check(cancelled.get() == 1 && cancelledCleanup.get() == 1,
                    "Waiting cancellation must complete and release exactly once");
            check(executor.requestCount() == 4, "Waiting cancellation kept its queue slot");
            release.countDown();
            await(completed);
            check(order.equals(List.of("visible-first", "visible-second", "background")),
                    "Visible requests or FIFO ordering lost priority: " + order);
        } finally {
            release.countDown();
            executor.close();
        }
        check(executor.awaitTermination(5, TimeUnit.SECONDS), "Priority workers did not stop");
    }

    private static void destroyCancelsRunningAndWaiting() throws Exception {
        NativeCurlExecutor executor = new NativeCurlExecutor(1, 1);
        CountDownLatch started = new CountDownLatch(1);
        CountDownLatch cancelledRunning = new CountDownLatch(1);
        AtomicInteger cancelled = new AtomicInteger();
        AtomicInteger cleaned = new AtomicInteger();
        executor.submit("running", 0, () -> {
            started.countDown();
            await(cancelledRunning);
        }, () -> {
            cancelled.incrementAndGet();
            cancelledRunning.countDown();
        }, cleaned::incrementAndGet);
        await(started);
        executor.submit("waiting", 0, () -> {
            throw new AssertionError("Activity destruction ran a waiting request");
        }, cancelled::incrementAndGet, cleaned::incrementAndGet);
        executor.close();
        executor.close();
        check(executor.awaitTermination(5, TimeUnit.SECONDS), "Activity destruction kept workers alive");
        check(cancelled.get() == 2 && cleaned.get() == 2 && executor.requestCount() == 0,
                "Activity destruction did not cancel/release every request");
        rejects(() -> executor.submit("after-destroy", 0, () -> {}, () -> {}, () -> {}));
    }
}
