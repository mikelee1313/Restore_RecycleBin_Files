# Restore_RecycleBin_Files
This script connects to each SharePoint Online site listed in a provided text file and restores items deleted within the last two days by a specific user ("MOD Administrator"). It authenticates using an Azure AD application with certificate-based authentication. Items are restored in batches of up to 200 items per API call to avoid throttling issues. The script logs detailed information about each step, including successful restorations, throttling events, and errors.



**Input File:**

![image](https://github.com/user-attachments/assets/7e39e788-3fe2-4c89-a13c-572d090255c9)

**Output File:**

![image](https://github.com/user-attachments/assets/ad551558-38f4-493f-8404-7425cc679609)

