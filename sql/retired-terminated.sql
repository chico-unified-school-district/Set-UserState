SELECT
 vwHREmploymentList.NameFirst,
 vwHREmploymentList.NameLast,
 vwHREmploymentList.NameMiddle,
 vwHREmploymentList.EmailWork,
 vwHREmploymentList.EmpID,
 vwHREmploymentList.BargUnitID,
 vwHREmploymentList.DateTerminationLastDay,
 vwHREmploymentList.DateTermination,
 HREmployment.EmploymentStatusCode
FROM vwHREmploymentList
 LEFT JOIN HREmployment ON HREmployment.EmpID = vwHREmploymentList.EmpID
WHERE
 -- Code 1,2: Certificated and Classified. Code 4: Contracted
 HREmployment.PersonTypeId IN (1,2,4)
 AND
 -- R: Retired T: Terminated
 HREmployment.EmploymentStatusCode IN ('R','T')
ORDER BY HREmployment.EmploymentStatusCode,vwHREmploymentList.empid