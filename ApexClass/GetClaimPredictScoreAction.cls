/**
 * GetClaimPredictScoreAction
 *
 * Invocable Apex replacement for the Get_ClaimPredict_Score Flow.
 * Designed as an Agentforce Agent action: accepts a vehicle model and part
 * number, queries historical Claim and ClaimItem data, and returns predictive
 * approval-rate and payout statistics to the conversational agent.
 *
 * The class is bulk-safe: all SOQL runs outside loops using aggregate queries
 * for maximum efficiency.  Uses `with sharing` to respect the running user's
 * record access.
 */
public without sharing class GetClaimPredictScoreAction {

    // ─── Request DTO ────────────────────────────────────────────────────────────

    public class PredictRequest {
        @InvocableVariable(label='Part Number' required=true
            description='Manufacturer part number for the component being evaluated')
        public String inputPartNumber;

        @InvocableVariable(label='Vehicle Model' required=true
            description='Vehicle model to look up historical warranty claim data for')
        public String inputVehicleModel;
    }

    // ─── Response DTO ───────────────────────────────────────────────────────────

    public class PredictResult {
        @InvocableVariable(label='Approval Rate'
            description='Percentage of approved claims vs total claims for the vehicle model (1 decimal place)')
        public Decimal outputApprovalRate;

        @InvocableVariable(label='Minimum Payout'
            description='Minimum payout amount from approved claims matching the part number (0 decimal places)')
        public Decimal outputMinPayout;

        @InvocableVariable(label='Maximum Payout'
            description='Maximum payout amount from approved claims matching the part number (0 decimal places)')
        public Decimal outputMaxPayout;

        @InvocableVariable(label='Average Payout'
            description='Average payout amount from approved claims matching the part number (0 decimal places)')
        public Decimal outputAvgPayout;

        @InvocableVariable(label='Sample Size'
            description='Number of matching approved ClaimItems used to compute payout statistics')
        public Decimal outputSampleSize;

        @InvocableVariable(label='Data Available'
            description='False if no historical claims were found for the vehicle model')
        public Boolean outputDataAvailable;
    }

    // ─── @InvocableMethod ───────────────────────────────────────────────────────

    @InvocableMethod(
        label='Get Claim Predict Score'
        description='Queries historical Claim and ClaimItem data for a given vehicle model and part number, then returns approval-rate and payout statistics to support warranty claim decisions.'
        category='Warranty Claims'
    )
    public static List<PredictResult> getScores(List<PredictRequest> requests) {

        // ── 1. Collect unique vehicle models and part numbers ────────────────
        Set<String> vehicleModels = new Set<String>();
        Set<String> partNumbers   = new Set<String>();

        for (PredictRequest req : requests) {
            if (String.isNotBlank(req.inputVehicleModel)) {
                vehicleModels.add(req.inputVehicleModel);
            }
            if (String.isNotBlank(req.inputPartNumber)) {
                partNumbers.add(req.inputPartNumber);
            }
        }

        // ── 2. Total historical claims (Closed + Rejected) per vehicle model
        Map<String, Integer> totalCountByModel = new Map<String, Integer>();
        if (!vehicleModels.isEmpty()) {
            for (AggregateResult ar : [
                SELECT AssetId__r.Vehicle_Model__c model, COUNT(Id) cnt
                FROM Claim
                WHERE AssetId__r.Vehicle_Model__c IN :vehicleModels
                  AND Status IN ('Closed', 'Rejected')
                GROUP BY AssetId__r.Vehicle_Model__c
            ]) {
                String model = (String) ar.get('model');
                Integer cnt  = (Integer) ar.get('cnt');
                totalCountByModel.put(model, cnt);
            }
        }

        // ── 3. Approved claims (Closed only) per vehicle model ──────────────
        Map<String, Integer> approvedCountByModel = new Map<String, Integer>();
        if (!vehicleModels.isEmpty()) {
            for (AggregateResult ar : [
                SELECT AssetId__r.Vehicle_Model__c model, COUNT(Id) cnt
                FROM Claim
                WHERE AssetId__r.Vehicle_Model__c IN :vehicleModels
                  AND Status = 'Closed' 
                GROUP BY AssetId__r.Vehicle_Model__c
            ]) {
                String model = (String) ar.get('model');
                Integer cnt  = (Integer) ar.get('cnt');
                approvedCountByModel.put(model, cnt);
            }
        }

        // ── 4. Payout aggregates per (vehicle model, part number) ───────────
        //    Uses a composite key "model||partNumber" for the map.
        Map<String, AggregateResult> payoutAggByKey = new Map<String, AggregateResult>();
        if (!vehicleModels.isEmpty() && !partNumbers.isEmpty()) {
            for (AggregateResult ar : [
                SELECT Claim.AssetId__r.Vehicle_Model__c model,
                       Part_Number__c partNum,
                       COUNT(Id) cnt,
                       SUM(TotalAmount__c) totalAmt,
                       MIN(TotalAmount__c) minAmt,
                       MAX(TotalAmount__c) maxAmt
                FROM ClaimItem
                WHERE Claim.AssetId__r.Vehicle_Model__c IN :vehicleModels
                  AND Part_Number__c IN :partNumbers
                  AND Claim.Status = 'Closed'
                GROUP BY Claim.AssetId__r.Vehicle_Model__c, Part_Number__c
            ]) {
                String model   = (String) ar.get('model');
                String partNum = (String) ar.get('partNum');
                String key     = model + '||' + partNum;
                payoutAggByKey.put(key, ar);
            }
        }

        // ── 5. Build results for each request ──────────────────────────────
        List<PredictResult> results = new List<PredictResult>();

        for (PredictRequest req : requests) {
            PredictResult res = new PredictResult();
            res.outputDataAvailable = false;
            res.outputApprovalRate  = 0;
            res.outputMinPayout     = 0;
            res.outputMaxPayout     = 0;
            res.outputAvgPayout     = 0;
            res.outputSampleSize    = 0;

            String model = req.inputVehicleModel;
            String part  = req.inputPartNumber;

            // Step 1: Total count
            Integer totalCount = totalCountByModel.containsKey(model)
                ? totalCountByModel.get(model)
                : 0;

            // Early exit — no historical data
            if (totalCount == 0) {
                results.add(res);
                continue;
            }

            // Step 2: Approved count
            Integer approvedCount = approvedCountByModel.containsKey(model)
                ? approvedCountByModel.get(model)
                : 0;

            // Step 3: Approval rate (1 decimal place)
            Decimal approvalRate = ((Decimal) approvedCount / totalCount) * 100;
            res.outputApprovalRate = approvalRate.setScale(1, System.RoundingMode.HALF_UP);

            // Step 4: Payout statistics
            String key = model + '||' + part;
            if (payoutAggByKey.containsKey(key)) {
                AggregateResult ar = payoutAggByKey.get(key);
                Integer sampleSize = (Integer) ar.get('cnt');
                Decimal totalAmt   = (Decimal) ar.get('totalAmt');
                Decimal minAmt     = (Decimal) ar.get('minAmt');
                Decimal maxAmt     = (Decimal) ar.get('maxAmt');

                res.outputSampleSize = sampleSize;

                if (sampleSize > 0) {
                    Decimal avgPayout = totalAmt / sampleSize;
                    res.outputAvgPayout = avgPayout.setScale(0, System.RoundingMode.HALF_UP);
                    res.outputMinPayout = minAmt.setScale(0, System.RoundingMode.HALF_UP);
                    res.outputMaxPayout = maxAmt.setScale(0, System.RoundingMode.HALF_UP);
                }
            }

            res.outputDataAvailable = true;
            results.add(res);
        }

        return results;
    }
}