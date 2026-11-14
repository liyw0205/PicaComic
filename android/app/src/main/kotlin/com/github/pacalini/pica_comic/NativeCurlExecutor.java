package com.github.pacalini.pica_comic;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.PriorityBlockingQueue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/** Bounded admission, fixed workers, and FIFO ordering within a priority. */
public final class NativeCurlExecutor implements AutoCloseable {
    private final ThreadPoolExecutor executor;
    private final Map<String, Request> requests = new HashMap<>();
    private final int capacity;
    private long nextSequence;
    private boolean closed;

    public NativeCurlExecutor(int workers, int maxQueued) {
        if (workers < 1 || maxQueued < 0) {
            throw new IllegalArgumentException("Invalid native curl capacity");
        }
        capacity = workers + maxQueued;
        // Admission below bounds running plus waiting requests; the queue never
        // grows beyond capacity, despite PriorityBlockingQueue being unbounded.
        executor = new ThreadPoolExecutor(workers, workers, 0, TimeUnit.SECONDS,
                new PriorityBlockingQueue<>());
    }

    public synchronized void submit(String id, int priority, Runnable action,
            Runnable onCancel, Runnable onFinished) {
        if (closed || requests.size() >= capacity || requests.containsKey(id)) {
            throw new RejectedExecutionException("Native curl queue is full or closed");
        }
        Request request = new Request(id, priority, nextSequence++, action,
                onCancel, onFinished);
        requests.put(id, request);
        try {
            executor.execute(request);
        } catch (RuntimeException error) {
            requests.remove(id);
            throw error;
        }
    }

    public void cancel(String id) {
        Request request;
        boolean removed;
        synchronized (this) {
            request = requests.get(id);
            if (request == null || !request.cancelled.compareAndSet(false, true)) return;
            removed = executor.remove(request);
            if (removed) requests.remove(id);
        }
        try {
            request.onCancel.run();
        } finally {
            if (removed) request.finish();
        }
    }

    public synchronized int requestCount() {
        return requests.size();
    }

    public boolean awaitTermination(long timeout, TimeUnit unit)
            throws InterruptedException {
        return executor.awaitTermination(timeout, unit);
    }

    @Override
    public void close() {
        ArrayList<String> ids;
        synchronized (this) {
            if (closed) return;
            closed = true;
            ids = new ArrayList<>(requests.keySet());
        }
        for (String id : ids) cancel(id);
        executor.shutdown();
    }

    private final class Request implements Runnable, Comparable<Request> {
        final String id;
        final int priority;
        final long sequence;
        final Runnable action;
        final Runnable onCancel;
        final Runnable onFinished;
        final AtomicBoolean cancelled = new AtomicBoolean();
        final AtomicBoolean finished = new AtomicBoolean();

        Request(String id, int priority, long sequence, Runnable action,
                Runnable onCancel, Runnable onFinished) {
            this.id = id;
            this.priority = priority;
            this.sequence = sequence;
            this.action = action;
            this.onCancel = onCancel;
            this.onFinished = onFinished;
        }

        @Override
        public int compareTo(Request other) {
            int byPriority = Integer.compare(other.priority, priority);
            return byPriority != 0 ? byPriority : Long.compare(sequence, other.sequence);
        }

        @Override
        public void run() {
            try {
                if (!cancelled.get()) action.run();
            } finally {
                synchronized (NativeCurlExecutor.this) {
                    requests.remove(id, this);
                }
                finish();
            }
        }

        void finish() {
            if (finished.compareAndSet(false, true)) onFinished.run();
        }
    }
}
