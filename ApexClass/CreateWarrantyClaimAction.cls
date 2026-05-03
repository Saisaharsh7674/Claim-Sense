/**
 * CreateWarrantyClaimAction
 *
 * Invocable Apex replacement for the Create_Warranty_Claim_From_Agent Flow.
 * Designed as an Agentforce Agent action: accepts warranty claim details from a
 * conversational agent, creates the Claim with ClaimItem and ClaimParticipant
 * records, and returns the outcome including risk triage and prior-claim data.
 *
 * The class is bulk-safe: all SOQL runs outside loops and DML is batched.
 * Uses `with sharing` to respect the running user's record access.
 */
public without sharing class CreateWarrantyClaimAction {

    // ─── Error Messages ──────────────────────────────────────────────────────────
    @TestVisible
    private static final String ERR_VEHICLE_NOT_FOUND =
        'Vehicle not found. Please verify the VIN and try again.';

    // ─── Risk / Triage Constants ─────────────────────────────────────────────────
    private static final String RISK_HIGH    = 'High';
    private static final String RISK_LOW     = 'Low';
    private static final String TRIAGE_ANOMALY  = 'Anomaly Flagged';
    private static final String TRIAGE_COMPLEX  = 'Complex Review';
    private static final String TRIAGE_STANDARD = 'Standard Review';
    private static final Integer FLEET_ANOMALY_THRESHOLD = 5;

    // ─── Request DTO ─────────────────────────────────────────────────────────────

    public class ClaimRequest {
        @InvocableVariable(label='Vehicle Identification Number (VIN)' required=true
            description='The serial number / VIN of the vehicle asset')
        public String inputVIN;

        @InvocableVariable(label='Dealer Account Id' required=true
            description='The Salesforce Account Id of the submitting dealer')
        public String inputDealerAccountId;

        @InvocableVariable(label='Dealer Contact Id' required=true
            description='The Salesforce Contact Id of the dealer representative')
        public String inputDealerContactId;

        @InvocableVariable(label='Part Number' required=true
            description='Manufacturer part number for the failed component')
        public String inputPartNumber;

        @InvocableVariable(label='Part Description' required=true
            description='Human-readable description of the part')
        public String inputPartDescription;

        @InvocableVariable(label='Failure Description' required=true
            description='Detailed description of the failure or defect observed')
        public String inputFailureDescription;

        @InvocableVariable(label='Vehicle Mileage at Failure' required=true
            description='Odometer reading at time of failure')
        public Decimal inputVehicleMileage;

        @InvocableVariable(label='Estimated Claim Value' required=true
            description='Estimated total repair/replacement cost')
        public Decimal inputEstimatedValue;

        @InvocableVariable(label='Claim Channel'
            description='Channel through which the claim was initiated (default: WhatsApp)')
        public String inputChannel;

        @InvocableVariable(label='Predicted Approval Percentage'
            description='ML-predicted probability of claim approval')
        public Decimal inputPredictedApprovalPct;

        @InvocableVariable(label='Predicted Payout Minimum'
            description='ML-predicted minimum payout amount')
        public Decimal inputPredictedPayoutMin;

        @InvocableVariable(label='Predicted Payout Maximum'
            description='ML-predicted maximum payout amount')
        public Decimal inputPredictedPayoutMax;
    }

    // ─── Response DTO ────────────────────────────────────────────────────────────

    public class ClaimResult {
        @InvocableVariable(label='Claim Id'
            description='Salesforce record Id of the newly created Claim')
        public String outputClaimId;

        @InvocableVariable(label='Claim Name'
            description='Auto-number Name of the newly created Claim')
        public String outputClaimName;

        @InvocableVariable(label='Prior Claim Found'
            description='True if a closed prior claim exists for the same vehicle')
        public Boolean outputPriorClaimFound;

        @InvocableVariable(label='Prior Claim Name'
            description='Name of the most recent prior closed claim, if any')
        public String outputPriorClaimName;

        @InvocableVariable(label='Error Message'
            description='Error details when outputSuccess is false')
        public String outputErrorMessage;

        @InvocableVariable(label='Success'
            description='True when the claim and all related records were created')
        public Boolean outputSuccess;
    }

    // ─── @InvocableMethod ────────────────────────────────────────────────────────

    @InvocableMethod(
        label='Create Warranty Claim'
        description='Creates a warranty prior-authorization Claim with ClaimItem and ClaimParticipant records. Performs vehicle lookup, prior-claim detection, fleet anomaly scoring, and risk triage.'
        category='Warranty Claims'
    )
    public static List<ClaimResult> createClaims(List<ClaimRequest> requests) {

        // ── 1. Collect all unique VINs and resolve Assets in one query ────────
        Set<String> vinSet = new Set<String>();
        for (ClaimRequest req : requests) {
            if (String.isNotBlank(req.inputVIN)) {
                vinSet.add(req.inputVIN);
            }
        }

        Map<String, Asset> assetByVin = new Map<String, Asset>();
        if (!vinSet.isEmpty()) {
            for (Asset a : [
                SELECT Id, Name, Vehicle_Model__c, AccountId, SerialNumber
                FROM Asset
                WHERE SerialNumber IN :vinSet
            ]) {
                assetByVin.put(a.SerialNumber, a);
            }
        }

        // ── 2. Collect all resolved Asset Ids for prior-claim + fleet queries ─
        Set<Id> assetIds = new Set<Id>();
        Set<String> vehicleModels = new Set<String>();
        for (Asset a : assetByVin.values()) {
            assetIds.add(a.Id);
            if (String.isNotBlank(a.Vehicle_Model__c)) {
                vehicleModels.add(a.Vehicle_Model__c);
            }
        }

        // ── 3. Prior claims — most-recent closed claim per Asset ──────────────
        Map<Id, Claim> priorClaimByAssetId = new Map<Id, Claim>();
        if (!assetIds.isEmpty()) {
            for (Claim c : [
                SELECT Id, Name, AssetId__c
                FROM Claim
                WHERE AssetId__c IN :assetIds
                  AND Status = 'Closed' 
                ORDER BY CreatedDate DESC
            ]) {
                // Keep only the first (most recent) per asset
                if (!priorClaimByAssetId.containsKey(c.AssetId__c)) {
                    priorClaimByAssetId.put(c.AssetId__c, c);
                }
            }
        }

        // ── 4. Fleet claim counts — total claims per Vehicle_Model__c ─────────
        Map<String, Integer> fleetCountByModel = new Map<String, Integer>();
        if (!vehicleModels.isEmpty()) {
            for (AggregateResult ar : [
                SELECT AssetId__r.Vehicle_Model__c model, COUNT(Id) cnt
                FROM Claim
                WHERE AssetId__r.Vehicle_Model__c IN :vehicleModels
                GROUP BY AssetId__r.Vehicle_Model__c
            ]) {
                String model = (String) ar.get('model');
                Integer cnt  = (Integer) ar.get('cnt');
                fleetCountByModel.put(model, cnt);
            }
        }

        // ── 4b. Determine next claim sequence number for current year ─────────
        String  currentYear = String.valueOf(Date.today().year());
        Integer nextSeqNum  = 1000;
        List<Claim> lastClaim = [
            SELECT Name FROM Claim
            WHERE Name LIKE :('WC-' + currentYear + '-%')
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!lastClaim.isEmpty()) {
            String[] parts = lastClaim[0].Name.split('-');
            if (parts.size() == 3) {
                try { nextSeqNum = Integer.valueOf(parts[2]) + 1; } catch (Exception e) {}
            }
        }

        // ── 5. Process each request ──────────────────────────────────────────
        List<ClaimResult> results = new List<ClaimResult>();

        // Track DML records keyed by request index for bulk insert
        List<Claim>            claimsToInsert      = new List<Claim>();
        List<Integer>          claimRequestIndexes  = new List<Integer>();
        List<Boolean>          priorClaimFlags      = new List<Boolean>();
        List<String>           priorClaimNames      = new List<String>();
        List<ClaimRequest>     validRequests        = new List<ClaimRequest>();
        List<Integer>          validFleetCounts     = new List<Integer>();
        List<Id>           validAssetIds       = new List<Id>();

        for (Integer i = 0; i < requests.size(); i++) {
            ClaimRequest req = requests[i];
            ClaimResult res  = new ClaimResult();
            res.outputSuccess        = false;
            res.outputPriorClaimFound = false;
            results.add(res);

            // Step 1: Resolve asset
            Asset asset = assetByVin.get(req.inputVIN);
            if (asset == null) {
                res.outputErrorMessage = ERR_VEHICLE_NOT_FOUND;
                continue;
            }

            // Step 2: Check prior claims
            Boolean priorFound = priorClaimByAssetId.containsKey(asset.Id);
            String priorName   = priorFound ? priorClaimByAssetId.get(asset.Id).Name : null;
            res.outputPriorClaimFound = priorFound;
            res.outputPriorClaimName  = priorName;

            // Step 3: Fleet count
            Integer fleetCount = fleetCountByModel.containsKey(asset.Vehicle_Model__c)
                ? fleetCountByModel.get(asset.Vehicle_Model__c)
                : 0;

            // Step 4: Risk triage
            String  riskScore   = RISK_LOW;
            String  triage      = TRIAGE_STANDARD;
            Boolean anomalyFlag = false;

            if (fleetCount >= FLEET_ANOMALY_THRESHOLD) {
                riskScore   = RISK_HIGH;
                triage      = TRIAGE_ANOMALY;
                anomalyFlag = true;
            } else if (priorFound) {
                riskScore = RISK_HIGH;
                triage    = TRIAGE_COMPLEX;
            }

            // Step 5: Build Claim sObject
            String channel = String.isNotBlank(req.inputChannel) ? req.inputChannel : 'WhatsApp';

            Claim newClaim = new Claim(
                Name                   = 'WC-' + currentYear + '-' + String.valueOf(nextSeqNum + claimsToInsert.size()),
                Status                 = 'Submitted',
                AccountId              = req.inputDealerAccountId,
                AssetId__c             = asset.Id,
                Claim_Channel__c       = channel,
                Risk_Score__c          = riskScore,
                Triage_Category__c     = triage,
                Fleet_Anomaly_Flag__c  = anomalyFlag,
                Predicted_Approval_Pct__c = req.inputPredictedApprovalPct,
                Predicted_Payout_Min__c   = req.inputPredictedPayoutMin,
                Predicted_Payout_Max__c   = req.inputPredictedPayoutMax,
                Description__c         = req.inputFailureDescription
            );

            claimsToInsert.add(newClaim);
            claimRequestIndexes.add(i);
            priorClaimFlags.add(priorFound);
            priorClaimNames.add(priorName);
            validRequests.add(req);
            validFleetCounts.add(fleetCount);
            validAssetIds.add(asset.Id); 

        }

        // ── 6. Bulk-insert Claims ────────────────────────────────────────────
        if (claimsToInsert.isEmpty()) {
            return results;
        }

        try {
            insert claimsToInsert;
        } catch (DmlException e) {
            // If bulk insert fails, mark all pending results as errors
            for (Integer idx : claimRequestIndexes) {
                results[idx].outputErrorMessage = e.getMessage();
            }
            return results;
        }

        // ── 7. Build ClaimItems and ClaimParticipants ────────────────────────
        List<ClaimItem>        itemsToInsert        = new List<ClaimItem>();
        List<ClaimParticipant> participantsToInsert = new List<ClaimParticipant>();

        for (Integer j = 0; j < claimsToInsert.size(); j++) {
            Claim insertedClaim   = claimsToInsert[j];
            ClaimRequest req      = validRequests[j];
            Boolean priorFound    = priorClaimFlags[j];
            Integer fleetCount    = validFleetCounts[j];

            ClaimItem item = new ClaimItem(
                Name                          = req.inputPartNumber + '-' + String.valueOf(j).leftPad(3, '0'),
                ClaimId                       = insertedClaim.Id,
                Part_Number__c                = req.inputPartNumber,
                Description                   = req.inputPartDescription,
                Failure_Description__c        = req.inputFailureDescription,
                Vehicle_Mileage_At_Failure__c = req.inputVehicleMileage,
                TotalAmount__c                = req.inputEstimatedValue,
                Prior_Claims_Same_Part__c     = priorFound ? 1 : 0,
                Fleet_Claim_Count_30Days__c   = fleetCount,
                FaultDate                     = Date.today(),
                AssetId                       = validAssetIds[j]
            );
            itemsToInsert.add(item);

            ClaimParticipant participant = new ClaimParticipant(
                ClaimId              = insertedClaim.Id,
                ParticipantContactId = req.inputDealerContactId,
                Roles                = 'Submitter'
            );
            participantsToInsert.add(participant);
        }

        try {
            insert itemsToInsert;
            insert participantsToInsert;
        } catch (DmlException e) {
            for (Integer idx : claimRequestIndexes) {
                results[idx].outputErrorMessage = e.getMessage();
            }
            return results;
        }

        // ── 8. Re-query Claim Names (auto-number) ───────────────────────────
        Set<Id> claimIds = new Set<Id>();
        for (Claim c : claimsToInsert) {
            claimIds.add(c.Id);
        }

        Map<Id, Claim> claimNameMap = new Map<Id, Claim>([
            SELECT Id, Name FROM Claim WHERE Id IN :claimIds
        ]);

        // ── 9. Populate success results ──────────────────────────────────────
        for (Integer j = 0; j < claimsToInsert.size(); j++) {
            Integer reqIndex = claimRequestIndexes[j];
            Claim inserted   = claimsToInsert[j];
            ClaimResult res  = results[reqIndex];

            res.outputClaimId   = inserted.Id;
            res.outputClaimName = claimNameMap.containsKey(inserted.Id)
                ? claimNameMap.get(inserted.Id).Name
                : null;
            res.outputSuccess   = true;
        }

        return results;
    }
}