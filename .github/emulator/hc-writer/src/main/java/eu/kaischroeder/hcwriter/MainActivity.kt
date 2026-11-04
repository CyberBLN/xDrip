package eu.kaischroeder.hcwriter

import android.app.Activity
import android.os.Bundle
import android.util.Log
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.metadata.Metadata
import kotlinx.coroutines.runBlocking
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import kotlin.concurrent.thread

/**
 * Writes test records to Health Connect and logs the result with the tag HCWRITER.
 *
 *   am start -W -n eu.kaischroeder.hcwriter/.MainActivity --es steps 100,120,150
 *
 * Writes 12 heart rate records with one sample each (every 10 minutes during the last two
 * hours, 61-72 bpm) and one 10 minute steps record per count in "steps" (a count may be 0).
 */
class MainActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val steps = intent.getStringExtra("steps")
        if (steps == null) {
            finish()
            return
        }
        thread {
            try {
                val records = buildRecords(steps.split(",").map { it.trim().toLong() })
                val client = HealthConnectClient.getOrCreate(this)
                val result = runBlocking { client.insertRecords(records) }
                Log.i(TAG, "OK inserted ${result.recordIdsList.size} records")
            } catch (e: Throwable) {
                Log.e(TAG, "FAILED $e")
            }
            runOnUiThread { finish() }
        }
    }

    private fun buildRecords(stepCounts: List<Long>): List<Record> {
        val now = Instant.now().truncatedTo(ChronoUnit.MINUTES)
        val offset = ZoneId.systemDefault().rules.getOffset(now)
        val records = mutableListOf<Record>()
        for (i in 1..12) {
            val time = now.minus(Duration.ofMinutes(10L * i))
            records += HeartRateRecord(
                time, offset, time.plusSeconds(1), offset,
                listOf(HeartRateRecord.Sample(time, 60L + i)),
                Metadata.manualEntry()
            )
        }
        stepCounts.forEachIndexed { i, count ->
            val start = now.minus(Duration.ofMinutes(15L + 30L * i))
            records += StepsRecord(start, offset, start.plus(Duration.ofMinutes(10)), offset, count, Metadata.manualEntry())
        }
        return records
    }

    companion object {
        private const val TAG = "HCWRITER"
    }
}
