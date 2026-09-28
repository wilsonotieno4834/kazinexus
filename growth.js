// Optional lightweight analytics helper for KaziNexus public pages.
window.kzEvent=function(name,jobId){try{const db=window.kzDb;if(db)db.from('site_events').insert({event_name:name,path:location.pathname,job_id:jobId||null,referrer:document.referrer||null}).then(()=>{}).catch(()=>{});}catch(e){}}
