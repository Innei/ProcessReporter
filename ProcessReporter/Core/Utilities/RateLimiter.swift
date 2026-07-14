//
//  RateLimiter.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/16.
//
//
//  Ratelimiter.swift
//  ProcessReporter
//

import Foundation

final class Ratelimiter: @unchecked Sendable {
    private let capacity: Int
    private let refillRate: Double // tokens per second
    private let minimumInterval: TimeInterval // 最小间隔时间
    private var tokens: Double
    private var lastRefillTimestamp: TimeInterval
    private var lastRequestTimestamp: TimeInterval?
    private let lock = NSLock()
    
    init(capacity: Int, refillRate: Double, minimumInterval: TimeInterval = 10) {
        self.capacity = capacity
        self.refillRate = refillRate
        self.minimumInterval = minimumInterval
        self.tokens = Double(capacity)
        self.lastRefillTimestamp = ProcessInfo.processInfo.systemUptime
    }
    
    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        // Use a monotonic clock. A wall-clock correction must not unexpectedly
        // refill the bucket or block requests for an arbitrary period.
        let now = ProcessInfo.processInfo.systemUptime
        
        // 检查最小间隔时间
        if let lastRequest = lastRequestTimestamp {
            let timeSinceLastRequest = now - lastRequest
            if timeSinceLastRequest < minimumInterval {
                return false
            }
        }
        
        // 更新令牌数量
        let timePassed = now - lastRefillTimestamp
        tokens = min(Double(capacity), tokens + timePassed * refillRate)
        lastRefillTimestamp = now
        
        if tokens >= 1 {
            tokens -= 1
            lastRequestTimestamp = now
            return true
        }
        
        return false
    }
}
